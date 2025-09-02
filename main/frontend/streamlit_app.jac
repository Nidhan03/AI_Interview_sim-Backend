import streamlit as st;
import tempfile;
import requests;
import time;
import base64;
import os;
import queue;
import streamlit.components.v1 as components;
import threading;
import asyncio;
import io;
import subprocess;
import json;
import websockets;
import from streamlit_ace {st_ace}
import from streamlit_autorefresh {st_autorefresh}


# -----------------------------
# Audio utilities (FFmpeg / playback)
# -----------------------------

# def silence_pcm16le_48000(duration_secs: float = 2.0) -> str{
#     cmd = [
#         "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
#         "-f", "lavfi", "-t", f"{duration_secs}",
#         "-i", "anullsrc=r=48000:cl=mono",
#         "-acodec", "pcm_s16le", "-ar", "48000", "-ac", "1",
#         "-f", "s16le", "pipe:1",
#     ];
#     proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE);
#     if proc.returncode != 0{
#         raise RuntimeError(f"ffmpeg failed: {proc.stderr.decode('utf-8', 'ignore')}");
#     }
#     return base64.b64encode(proc.stdout).decode("utf-8");
# }

def to_pcm16le_48000(raw_wav_bytes: bytes) -> list[str]{
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-i", "pipe:0",          # input: WAV bytes (self-describing)
        "-acodec", "pcm_s16le",  # OUTPUT codec: signed 16-bit little-endian
        "-ar", "48000",          # OUTPUT sample rate: 48 kHz
        "-ac", "1",              # OUTPUT channels: mono (mixdown if needed)
        "-f", "s16le",           # OUTPUT container: raw PCM (no header)
        "pipe:1"                 # output to stdout
    ];
    
    proc = subprocess.run(cmd, input=raw_wav_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE);
    if proc.returncode != 0{
        raise RuntimeError(f"ffmpeg failed: {proc.stderr.decode('utf-8', 'ignore')}");
    }

    pcm_bytes = proc.stdout;

    bytes_per_second = 48000 * 2;
    chunk_size = 10 * bytes_per_second;  
    chunks = [];
    for i in range(0, len(pcm_bytes), chunk_size){
        chunk = pcm_bytes[i:i+chunk_size];
        if chunk{
            chunks.append(base64.b64encode(chunk).decode("utf-8"));
        }
    }
    return chunks;
}

def autoplay_from_base64_pcm16le_48000(b64_list: list[str]) -> None{
    pcm_list = [base64.b64decode(s) for s in b64_list if s];
    total_pcm = b"".join(pcm_list);
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-f", "s16le", "-ar", "48000", "-ac", "1",
        "-i", "pipe:0",
        "-c:a", "pcm_s16le", "-f", "wav",
        "pipe:1"
    ];
    proc = subprocess.run(cmd, input=total_pcm, stdout=subprocess.PIPE, stderr=subprocess.PIPE);
    if proc.returncode != 0{
        raise RuntimeError(f"ffmpeg failed: {proc.stderr.decode('utf-8', 'ignore')}");
    }
    wav_b64 = base64.b64encode(proc.stdout).decode("utf-8");
    components.html("""
        <audio id="auto-audio" autoplay playsinline>
            <source src="data:audio/wav;base64,%s">
            Your browser does not support the audio element.
        </audio>
        <script>
        const a = document.getElementById('auto-audio');
        if (a) {
            const tryPlay = () => a.play().catch(()=>{});
            a.addEventListener('canplay', tryPlay, { once: true });
            tryPlay();
        }
        </script>
    """ % (wav_b64), height=0);
    duration_sec = len(total_pcm) / (48000 * 2);
    table_placeholder = st.empty();
    if st.session_state.show_code_editor {
        with table_placeholder.container(border = True){
            display_python_code_editor();
        }
    }
    time.sleep(duration_sec);
}


# -----------------------------
# WebSocket worker / thread bootstrap
# -----------------------------

async def ws_worker(send_q: Queue, recv_q: Queue, agent_id: str, user_name: str, stop_event: threading.Event){ 
    async with websockets.connect(
        f"wss://api.elevenlabs.io/v1/convai/conversation?agent_id={agent_id}"
        ,max_size=8 * 1024 * 1024) as ws {

        init = {
            "type": "conversation_initiation_client_data",
            "dynamic_variables": {
                "user_name" : user_name
            }
        };
        await ws.send(json.dumps(init));

        async def reader() {
            try {
                async for msg in ws{
                    if stop_event.is_set(){
                        await ws.close();
                        break;
                    }
                    data = json.loads(msg);
                    if data.get("type") != "audio"{
                        print(data);
                    }
                    
                    if data.get("type") == "ping"{
                        await ws.send(json.dumps({
                            "type": "pong",
                            "event_id": data["ping_event"]["event_id"]
                        }));
                    }
                    else{
                        recv_q.put(msg);
                    }
                }

            }
            except Exception as e {
                recv_q.put(json.dumps({"type": "error", "detail": str(e)}));
            }
        }

        async def writer() {
            while True {
                if stop_event.is_set(){
                    await ws.close();
                    break;
                }
                try {
                    payload = await asyncio.get_event_loop().run_in_executor(None, send_q.get);
                }
                except Exception {
                    break;
                }
                await ws.send(json.dumps(payload));
            }
        }

        await asyncio.gather(reader(), writer());
    }
}

def start_ws_thread() {
    def runner(send_q: Queue, recv_q: Queue, agent_id: str, user_name: str, stop_event: threading.Event){
        asyncio.run(ws_worker(send_q, recv_q, agent_id, user_name, stop_event ));
    }
    if not (st.session_state.ws_thread and st.session_state.ws_thread.is_alive()){
        t = threading.Thread(target=runner, args = (st.session_state.send_q, st.session_state.recv_q, st.session_state.agent_id , st.session_state.user_name, st.session_state.stop_event), daemon=True);
        t.start();
        st.session_state.ws_thread = t;
    }
    
}


# -----------------------------
# Code editor helpers (UI + problem display)
# -----------------------------

def display_python_code_editor() {
    def run_python(code_text: str) {
        with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False, encoding="utf-8") as tmp {
            tmp.write(code_text);
            path = tmp.name;
        }

        try {
            proc = subprocess.run(["python", path], capture_output=True, text=True, timeout=10);
        } except subprocess.TimeoutExpired {
            return "⏱️ Execution timed out.";
        }

        (out, err) = (proc.stdout.strip(), proc.stderr.strip());
        if proc.returncode != 0 {
            return f"⛔ Error:\n{err or out}";
        }
        return out or "(no output)";
    }

    display_coding_problem(st.session_state.coding_problem);

    code = st_ace(
        value=st.session_state["python_editor"],
        theme="dracula",
        language="python",
        min_lines=12,
        key="python_editor"  
    );

    run = st.button("▶️ Run code");

    if run {
        result = run_python(code);
        st.code(result, language="text");
        st.session_state["last_code_output"] = result;
    }else{
        st.code(st.session_state["last_code_output"], language="text");
    }

    if st.button("Submit Solution"){
        st.session_state.send_q.put({
                "type": "user_message",
                "text": "User is done with the coding problem",
            });
        
        st.session_state.show_code_editor = False;
        st.rerun();
    }
    
        
}

def display_coding_problem(data: dict){    
   
    st.markdown("#### Problem Statement");
    st.markdown(data['problem_statement']);

    st.markdown("#### Input Format");
    st.markdown(data['input_format']);

    st.markdown("#### Output Format");
    st.markdown(data['output_format']);

    st.markdown("#### Constraints");
    st.markdown(data['constraints']);

    st.markdown("#### Example Test Cases");
    st.markdown(f"```text\n{data['example_test_cases']}\n```");

}


# -----------------------------
# Interview lifecycle helpers
# -----------------------------

def end_interview(){
    st.session_state.stop_event.set();
    st.session_state.interview_over = True;

    payload = {
        "session_id": st.session_state.session_id,
        "conversation_history": st.session_state.conversation_history,
        "coding_solution": st.session_state["python_editor"] if st.session_state.job_description == "Technical" else ""
    };

    try{
        response = requests.post(
            "http://localhost:8000/walker/end_interview_session",
            json=payload,
        );
        response.raise_for_status();
    }
    except requests.exceptions.RequestException as e{
        st.error(f"Could not end interview: {e}");
    }

    st.rerun();
}


# -----------------------------
# Page renderers (Form → Simulator → Feedback)
# -----------------------------

def render_interview_form(){
    st.title("Welcome to the AI Interview Simulator!");
    (col1, col2) = st.columns(2);
    with col1{
        interview_type = st.selectbox(
            "Interview Type",
            [
                "Behavioral",
                "Situational",
                "Technical",
                "Case Study",
                "HR/Personality",
                "Problem-Solving",
                "Academic"
            ]
        );
    }
    with col2{
        duration = st.text_input(
            "Interview Duration (minutes)",
            placeholder="Max time: 30 mins",
            help="Enter a number in minutes (e.g., 15, 30)"
        );
        if duration{
            try{
                duration_int = int(duration);
                if duration_int <= 0 or duration_int > 30{
                    st.error("Please enter a duration between 1 and 30 minutes.");
                }
            }
            except ValueError{
                st.error("Please enter a valid number for duration.");
            }
    }
    }
    job_description = st.text_area("Job Description", height=150);
    resume_file = st.file_uploader("Upload Resume or Additional Info (Optional)", ["pdf", "docx", "txt"]);
    
    
    if st.button("Submit"){
    
        if not interview_type or not duration or not job_description.strip(){
            st.error("⚠️ Please complete all the essential fields.");
        }else{
            st.write("**Interview Type:**", interview_type);
            st.write("**Duration:**", f"{duration} minutes");
            st.write("**Job Description:**", job_description);
            if resume_file{
                st.write("**File Uploaded:**", resume_file.name);
            }else{
                st.write("**No file uploaded.**");
            }

            file_uploaded = False if (resume_file == None) else True;

            if resume_file != None{
                resume_file_name = resume_file.name;
                resume_file_data = base64.b64encode(resume_file.getvalue()).decode('utf-8');
            }else{
                resume_file_name = "";
                resume_file_data = "";
            }
            payload = {
                "interview_type": interview_type,
                "job_description": job_description,
                "duration": duration,
                "file_uploaded": file_uploaded,
                "file_name": resume_file_name,
                "file_data": resume_file_data,
            };
            with st.spinner("Creating interview session..."){
                response = requests.post("http://localhost:8000/walker/create_interview_session", json=payload);
            }
            if response.status_code == 200{
                session_id = response.json()["reports"][0]["session_id"];
                agent_id = response.json()["reports"][0]["agent_id"];
                st.session_state.coding_problem = response.json()["reports"][0]["coding_problem"];
                st.session_state.job_description = job_description;
                st.session_state.session_id = session_id;
                st.session_state.agent_id = agent_id;
                st.success(f"Interview session created successfully! Session ID: {session_id}");
            
            }else{
                st.error("Failed to create interview session. Please try again.");
            }
            

        }

    }
    if st.session_state.session_id != ""{
        if st.button("Go to Interview Simulator"){
            st.switch_page(st.Page(render_interview_simulator, title="Interview Simulator",));
        }
    }
}

def render_interview_simulator(){
    if st.session_state.session_status == "Not Started" {
        (col1,col2,col3) = st.columns([1.35, 2, 1.2]);
        with col2{
            with st.form("Name submission form", width = 450, height = 200) {
                user_name = st.text_input("Name", placeholder="Enter your name to start the interview");
                submitted = st.form_submit_button("Submit");
                if submitted{
                    if user_name.strip() == ""{
                        st.error("Please enter your name to start the interview.");
                    }
                    else{
                        st.session_state.user_name = user_name;
                        st.session_state.session_status = "started";
                        start_ws_thread();
                        st.rerun();
                    }
                }
            }
        }
    }

    if (st.session_state.session_status == "started"){
        found_first_agent = False;
        while True {
            try {
                raw = st.session_state.recv_q.get_nowait();
            } except queue.Empty {
                break;
            } else {
                try {
                    resp = json.loads(raw);
                } except Exception {
                    resp = {"type": "text", "text": str(raw)};
                }

                rtype = resp.get("type");
                if rtype == "conversation_initiation_metadata"{
                    found_first_agent = True;
                }
            }
        }

        if not found_first_agent {
            st.info("Connecting… waiting for the first response.");
            st_autorefresh(500, key="poll_first_msg");
        } else {
            st.session_state.session_status = "in_progress";
        }
    }
    if st.session_state.session_status == "in_progress"{
        with st.sidebar{
            audio_user = st.audio_input("Say something...");
            st.info("Audio functionality is currently under development.");
            if audio_user{
                audio_bytes = audio_user.getvalue();
                user_audio_chunks = to_pcm16le_48000(audio_bytes);

                if st.session_state.last_sent_audio != user_audio_chunks{
                    for audio_chunk in user_audio_chunks{
                        st.session_state.send_q.put({
                            "user_audio_chunk": audio_chunk
                            });
                    }

                    st.session_state.last_sent_audio = user_audio_chunks;
                    st.rerun();
                }
            }
            if st.session_state.interview_over == False{
                if st.button("End Interview"){
                    end_interview();
                }
            }else{
                st.info("Interview Ended");
                if st.button("View feedback"){
                    st.switch_page(st.Page(render_feedback_form, title="Feedback Form"));
                }
            }

            
        }
            
        while True {
            try {
                raw = st.session_state.recv_q.get_nowait();
            } except queue.Empty {
                break;
            } else {
                try {
                    resp = json.loads(raw);
                } except Exception {
                    resp = {"type": "text", "text": str(raw)};
                }

                if resp["type"] == "agent_response"{
                    st.session_state.messages.append({
                        "role": "assistant",
                        "content": resp["agent_response_event"]["agent_response"],
                        "audio_chunks": st.session_state.pending_audio.copy(),
                        "audio_played": False,
                    });
                    st.session_state.conversation_history.append({
                        "role": "assistant",
                        "content": resp["agent_response_event"]["agent_response"],
                    });
                    st.session_state.pending_audio.clear();
                }
                if resp["type"] == "user_transcript"{
                    user_message = ({"role": "user", "content": resp["user_transcription_event"]["user_transcript"]});
                    st.session_state.messages.append(user_message);
                    st.session_state.conversation_history.append(user_message);
                }
                if resp["type"] == "audio"{
                    response_audio = resp["audio_event"]["audio_base_64"];
                    st.session_state.pending_audio.append(response_audio);
                }
                if resp["type"] == "client_tool_call"{
                    st.session_state.show_code_editor = True;
                    st.session_state.send_q.put({
                    "type": "client_tool_result",
                    "tool_call_id": resp["client_tool_call"]["tool_call_id"],
                    "result": "Code editor redered to the user",
                    "is_error": False
                    });
                }
                if resp["type"] == "agent_tool_response"{
                    if resp["agent_tool_response"]["tool_name"] == "end_call"{
                        end_interview();
                    }
                }

                st.rerun();
            }
        }

        st.session_state.send_q.put({
                "type": "user_activity",
        });

        for m in st.session_state.messages {
            with st.chat_message(m["role"]) {
                st.markdown(m["content"]);
                if m.get("audio_played") == False{
                    autoplay_from_base64_pcm16le_48000(m.get("audio_chunks"));
                    m["audio_played"] = True;
                    st.rerun();
                }
                
            }
        }
        table_placeholder = st.empty();
        if st.session_state.show_code_editor {
            with table_placeholder.container(border = True){
                display_python_code_editor();
            }
        }
        
        prompt = st.chat_input("Type your message");
        if prompt {
            st.session_state.messages.append({"role": "user", "content": prompt});
            st.session_state.send_q.put({
                "type": "user_message",
                "text": prompt,
            });
            
            st.rerun();
        }
        st_autorefresh(500, key="poll_firstmsg");
    }  
}

def render_feedback_form(){
    st.title("Interview Feedback Form");
}


# -----------------------------
# App entry / session init
# -----------------------------

with entry{

    if "session_status" not in st.session_state{
        st.session_state.session_status = "Not Started";
        if "send_q" not in st.session_state{
            st.session_state.send_q = queue.Queue();
        }
        if "recv_q" not in st.session_state{
            st.session_state.recv_q = queue.Queue();
        }
    }
    if "interview_results" not in st.session_state{
        st.session_state.interview_results = {};
    }
    if "python_editor" not in st.session_state {
        st.session_state["python_editor"] = 'print("Hello world!")';
    }

    if "last_code_output" not in st.session_state{
        st.session_state["last_code_output"] = "Hello World!";
    }
    if "pending_audio" not in st.session_state{
        st.session_state.pending_audio = [];
    }
    if "stop_event" not in st.session_state{
        st.session_state.stop_event = threading.Event();
    }
    if "session_id" not in st.session_state{
        st.session_state.session_id = "";
    }
    if "agent_id" not in st.session_state{
        st.session_state.agent_id = "";
    }
    if "user_name" not in st.session_state{
        st.session_state.user_name = "";
    }
    if "messages" not in st.session_state{
        st.session_state.messages = [];
    }
    if "ws_thread" not in st.session_state {
        st.session_state.ws_thread = None;
    }
    if "last_sent_audio" not in st.session_state{
        st.session_state.last_sent_audio = None;
    }
    if "show_code_editor" not in st.session_state{
        st.session_state.show_code_editor = False;
    }
    if "coding_problem" not in st.session_state{
        st.session_state.coding_problem = {};
    }
    if "interview_over" not in st.session_state{
        st.session_state.interview_over = False;
    }
    if "job_description" not in st.session_state{
        st.session_state.job_description = "";
    }

    if "conversation_history" not in st.session_state{
        st.session_state.conversation_history = [];
    }


    st.set_page_config(
        page_title="AI Interview Simulator",
        layout="wide"
    );

    selected_page = st.navigation(
        [
        st.Page(
            render_interview_form, 
            title="Interview Form",
            default=True,
       
            ),
        st.Page(
            render_interview_simulator, 
            title="Interview Simulator",
            ),
        st.Page(
            render_feedback_form, 
            title="Feedback Form",
            )
        ],
        position = "hidden",
    );
                    

    selected_page.run();

}
