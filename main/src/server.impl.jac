import os;
import base64;
import from code_analyzer {build_python_context_graph}
import requests;
import from tools {generate_coding_problem, generate_interview_agent_prompt, RagEngine, generate_overall_feedback_report }


impl CreateInterview.save_file(session_id: str, file_name: str, file_data: str){
    UPLOAD_DIR = os.path.join("data/docs", session_id);
    if not os.path.exists(UPLOAD_DIR) {
        os.makedirs(UPLOAD_DIR);
    }

    file_path = os.path.join(UPLOAD_DIR, file_name);
    data = base64.b64decode(file_data.encode('utf-8'));

    with open(file_path, 'wb') as f {
        f.write(data);
    }

    lower_name = file_name.lower();
    if lower_name.endswith(".pdf") or lower_name.endswith(".txt") {
        rag_engine.add_file(file_path);
    }

    return {
        "status": "uploaded",
        "file_path": file_path,
        "added_to_rag": lower_name.endswith(".pdf") or lower_name.endswith(".txt")
    };
}

impl CreateInterview.create_interview_agent{
    print("Creating interview..");

    if visitor.file_uploaded == True{
        self.file_path = self.save_file(jid(self), visitor.file_name, visitor.file_data)["file_path"];
    }

    cv_data = "No CV data provided.";
    url = "https://api.elevenlabs.io/v1/convai/agents/create";
    tool_url = "https://api.elevenlabs.io/v1/convai/tools";
    headers = {
        "xi-api-key": os.getenv("ELEVENLABS_API_KEY")
    };

    coding_problem = {};

    if visitor.interview_type == "Technical" {
        tool_url = "https://api.elevenlabs.io/v1/convai/tools";
        tool_data = {
            "tool_config": {
                "name": "ShowCodeEditor",
                "description": "Display a code editor for the user to write code and run code, when the user has to solve a coding question.",
                "type": "client",
                "disable_interruptions": True,
            }
        };

        tool_response = requests.post(tool_url, headers=headers, json=tool_data);
        tool_response.raise_for_status();
        self.tool_id = tool_response.json()["id"];
        coding_problem = generate_coding_problem(visitor.job_description);
    }

    if visitor.file_uploaded == "True"{
        cv_data = rag_engine.search("Extract and write a concise overall summary of the candidate’s profile from this CV, highlighting background, skills, experience, and career goals.");
    }

    prompt = generate_interview_agent_prompt(
        visitor.duration, visitor.interview_type, visitor.job_description, cv_data, coding_problem
    );

    data = {
        "conversation_config": {
            "asr": {
                "quality": "high",
                "provider": "elevenlabs",
                "user_input_audio_format": "pcm_48000"
            },
            "turn": {
                "turn_timeout": 60,
                "mode": "silence"
            },
            "tts": {
                "agent_output_audio_format": "pcm_48000"
            },
            "conversation": {
                # duration must be in seconds
                "max_duration_seconds": int(visitor.duration) * 60,
                "client_events": [
                    "vad_score",
                    "user_transcript",
                    "agent_response",
                    "audio",
                    "ping",
                    "conversation_initiation_metadata",
                    "client_tool_call",
                    "agent_tool_response"
                ]
            },
            "agent": {
                "first_message": "Hi {{user_name}}, are you ready to begin your interview?",
                "prompt": {
                    "prompt": prompt,
                    "tool_ids": [self.tool_id] if visitor.interview_type == "Technical" else [],
                    "built_in_tools": {
                        "end_call": {
                            "type": "system",
                            "name": "end_call",
                            "description": "",
                            "params": {
                                "system_tool_type": "end_call",
                                "transfers": [],
                                "voicemail_message": ""
                            },
                            "disable_interruptions": False
                        }
                    }
                }
            }
        },
        "name": "interview_agent"
    };

    response = requests.post(url, headers=headers, json=data);
    response.raise_for_status();
    self.agent_id = response.json()["agent_id"];

    visitor.session_history.append({"activity": "Interview has been created"});
    print("Interview created!");
    report {"session_id": jid(self), "agent_id": self.agent_id, "coding_problem": coding_problem, "session_history": visitor.session_history};
}


impl EndInterview.get_interview_results{
    print("Ending interview & getting feedback ...");
    code_context_graph = "No code context graph available.";
    if visitor.interview_type == "Technical"{
        code_context_graph = str(build_python_context_graph(visitor.coding_solution));
    }

    self.feedback = generate_overall_feedback_report(
        visitor.interview_type, visitor.job_description, visitor.conversation_history, visitor.coding_problem, code_context_graph
    );

    visitor.session_history.append({"activity": "Interview has been ended"});
    print("Ended interview & feedback generated!");
    print(visitor.session_history);
    report {"interview_results": self.feedback, "session_history": visitor.session_history};
}
