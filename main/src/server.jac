import uuid;
import os;
import base64;
import requests;
import from tools { RagEngine, generate_coding_problem, generate_interview_agent_prompt, summarize_overall_feedback, generate_overall_feedback_report };

glob rag_engine:RagEngine = RagEngine();

node Session {
    has session_id: str;
    has interview_type: str;
    has job_description: str;
    has duration: str;
    has file_uploaded: bool;
    has file_path: str;
    has chat_history: list[dict] = [];
    has agent_id: str = "";
    has tool_id: str = "";

    # Store problem/solution on the session
    has coding_problem: dict = {};
    has coding_solution: str = "";

    can create_interview_agent with create_interview_session entry {
        cv_data = "No CV data provided.";
        coding_problem = {};
        url = "https://api.elevenlabs.io/v1/convai/agents/create";
        tool_url = "https://api.elevenlabs.io/v1/convai/tools";
        headers = {
            "xi-api-key": os.getenv("ELEVENLABS_API_KEY")
        };

        if self.interview_type == "Technical" {
            tool_data = {
                "tool_config": {
                    "name": "ShowCodeEditor",
                    "description": "Display a code editor for the user to write code and run code, when the user has to solve a coding question.",
                    "type": "client",
                    "disable_interruptions": True
                }
            };
            tool_response = requests.post(tool_url, headers=headers, json=tool_data);
            tool_response.raise_for_status();
            self.tool_id = tool_response.json()["id"];
            coding_problem = generate_coding_problem(self.job_description);
        }

        if self.file_uploaded {
            cv_data = rag_engine.search("Extract and write a concise overall summary of the candidate’s profile from this CV, highlighting background, skills, experience, and career goals.");
        }

        # persist coding_problem on the session
        self.coding_problem = coding_problem;

        prompt = generate_interview_agent_prompt(self.duration, self.interview_type, self.job_description, cv_data, coding_problem);
        std.out(prompt);

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
                    "max_duration_seconds": int(self.duration) * 60,
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
                        "tool_ids": [self.tool_id] if self.interview_type == "Technical" else [],
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

        report {"session_id": self.session_id, "agent_id": self.agent_id, "coding_problem": coding_problem};
    }
}

walker create_interview_session {
    has interview_type: str;
    has job_description: str;
    has duration: str;
    has file_uploaded: bool;
    has file_name: str;
    has file_data: str;

    obj __specs__ {
        static has auth: bool = False;
    }

    def save_file(session_id: str, file_name: str, file_data: str) {
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

    can save_interview_data with root entry {
        session_id = str(uuid.uuid4());
        std.out(f"session: {session_id} created");

        file_path = "";
        if self.file_uploaded {
            file_path = self.save_file(session_id, self.file_name, self.file_data)["file_path"];
        }

        new_session = Session(session_id, self.interview_type, self.job_description, self.duration, self.file_uploaded, file_path);
        root ++> new_session;
        visit new_session;
    }
}

walker end_interview_session {
    has session_id: str;
    has agent_id: str;
    has coding_solution: str;

    obj __specs__ {
        static has auth: bool = False;
    }

    can end_session with root entry {
        target = None;
        for s in root::Session {
            if s.session_id == self.session_id {
                target = s;
                break;
            }
        }
        if target != None {
            target.coding_solution = self.coding_solution;
            report {"saved": True, "session_id": self.session_id};
        } else {
            report {"saved": False, "error": "Session not found", "session_id": self.session_id};
        }
    }
}

walker GenerateOverallFeedback {
    has session_id: str;

    obj __specs__ {
        static has auth: bool = False;
    }

    can generate with root entry {
        sess = None;
        for s in root::Session {
            if s.session_id == self.session_id {
                sess = s;
                break;
            }
        }
        if sess == None {
            report {"error": "Session not found", "session_id": self.session_id};
            return;
        }

        # Build transcript from chat_history
        convo = "";
        for m in sess.chat_history {
            role = "user";
            if "role" in m { role = m["role"]; }
            text = "";
            if "content" in m { text = m["content"]; }
            else if "text" in m { text = m["text"]; }
            line = f"{role}: {text}\n";
            convo += line;
        }
        if len(convo) > 8000 {
            convo = convo[-8000:];
        }

        cp_str = "";
        if len(sess.coding_problem) > 0 {
            cp_str = str(sess.coding_problem);
        }

        result = generate_overall_feedback_report(
            sess.interview_type,
            sess.job_description,
            convo,
            cp_str,
            sess.coding_solution
        );

        std.out(result);
        report {"session_id": sess.session_id, "overall_feedback": result};
    }
}
