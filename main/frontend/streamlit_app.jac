import streamlit as st;
import requests;
import numpy;
import time;
import base64;
import wave;
import os;
import queue;
import streamlit.components.v1 as components;
import threading;
import asyncio;
import io;
import subprocess;
import json;
import from streamlit_autorefresh {st_autorefresh}
import websockets;



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




def from_base64_pcm16le_16000(b64_str: str) -> bytes{
    pcm_data = base64.b64decode(b64_str);  # Step 1: decode base64 to raw PCM
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-f", "s16le",       # raw PCM input format
        "-ar", "16000",      # sample rate
        "-ac", "1",          # mono
        "-i", "pipe:0",      # read from stdin
        "-c:a", "pcm_s16le", # keep same encoding
        "-f", "wav",         # output format: WAV
        "pipe:1"             # write output to stdout
    ];
    proc = subprocess.run(cmd, input=pcm_data, stdout=subprocess.PIPE, stderr=subprocess.PIPE);
    if proc.returncode != 0{
        raise RuntimeError(f"ffmpeg failed: {proc.stderr.decode('utf-8', 'ignore')}");
    }
    return proc.stdout;  # WAV bytes
}

def autoplay_from_base64_pcm16le_16000(b64_str: str) -> None{
    # 1) base64 PCM -> bytes
    pcm = base64.b64decode(b64_str);
    # 2) raw PCM -> WAV via ffmpeg
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-f", "s16le", "-ar", "16000", "-ac", "1",
        "-i", "pipe:0",
        "-c:a", "pcm_s16le", "-f", "wav",
        "pipe:1"
    ];
    proc = subprocess.run(cmd, input=pcm, stdout=subprocess.PIPE, stderr=subprocess.PIPE);
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


}

async def ws_worker(send_q: Queue, recv_q: Queue, agent_id: str, user_name: str, stop_event: threading.Event){ 
    async with websockets.connect(
        f"wss://api.elevenlabs.io/v1/convai/conversation?agent_id={agent_id}"
        ) as ws {

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
                    
                    if data.get("type") == "ping"{
                        await ws.send(json.dumps({
                            "type": "pong",
                            "event_id": data.get("ping_event", {}).get("event_id")
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
            audio_user = st.audio_input("Say something");
            if audio_user{
                audio_bytes = audio_user.getvalue();
                pcm_bytes = to_pcm16le_16000(audio_bytes);

                if st.session_state.last_sent_audio != pcm_bytes{
                    st.session_state.send_q.put({
                    "user_audio_chunk": base64.b64encode(pcm_bytes).decode("utf-8"),
                    });
                    st.session_state.last_sent_audio = pcm_bytes;
                    st.rerun();
                    
                }
            }
            if st.button("End interview"){
                st.info("Interview Ended");
                st.session_state.stop_event.set();
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
                    st.session_state.messages.append({"role": "assistant", "content": resp["agent_response_event"]["agent_response"]});
                }
                if resp["type"] == "user_transcript"{
                    st.session_state.messages.append({"role": "assistant", "content": resp["user_transcription_event"]["user_transcript"]});
                }
                st.rerun();
                # if resp["type"] == "audio"{

                #     response_audio = autoplay_from_base64_pcm16le_16000(resp["audio_event"]["audio_base_64"]);
                #     pcm = base64.b64decode(response_audio);
                #     time.sleep(7);
                # }
                
            }
        }

        for m in st.session_state.messages {
            with st.chat_message(m["role"]) {
                st.markdown(m["content"]);
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
            )
        ],
        position = "hidden",
    );

    
    selected_page.run();

}

