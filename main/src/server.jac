import uuid;
import os;
import base64;
import requests;

/* Tools used by the agent endpoints */
import from tools {
    gen_nontech_questions,
    gen_tech_questions,
    eval_nontech_answer,
    summarize_feedback,
    make_voice_prompt,
    answer_with_context
};

/* RAGTEXT is defined in rag_text.jac (serve that file alongside this one) */
import from rag_text { RAGTEXT };

/* =========================
   Session + ConvAI (ElevenLabs)
   ========================= */
node Session {
    has session_id: str;
    has interview_type: str;
    has job_description: str;
    has duration: str;
    has file_uploaded: bool;
    has file_path: str;
    has list[dict] chat_history = [];
    has str agent_id = "";

    can create_interview_agent with create_interview_session entry {
        url = "https://api.elevenlabs.io/v1/convai/agents/create";
        headers = {
            "xi-api-key": os.getenv("ELEVENLABS_API_KEY")
        };
        data = {
            "conversation_config": {
                "asr": {
                    "quality": "high",
                    "provider": "elevenlabs",
                    "user_input_audio_format": "pcm_16000"
                },
                "turn": {
                    "turn_timeout": 20,
                    "mode": "silence"
                },
                "tts": {
                    "agent_output_audio_format": "pcm_16000"
                },
                "conversation": {
                    "max_duration_seconds": int(self.duration) * 60,
                    "client_events": [
                        "vad_score",
                        "user_transcript",
                        "agent_response",
                        "audio",
                        "ping",
                        "conversation_initiation_metadata"
                    ]
                },
                "agent": {
                    "first_message": "Hi {{user_name}}, are you ready to begin your interview?",
                    "prompt": {
                        "prompt": f"You are an AI interview agent. Your task is to conduct a {self.interview_type} interview for the position of {self.job_description} with {{user_name}}. Please ask relevant and engaging questions."
                    }
                }
            },
            "name": "interview_agent"
        };

        response = requests.post(url, headers=headers, json=data);
        response.raise_for_status();
        self.agent_id = response.json()["agent_id"];

        report { "session_id": self.session_id, "agent_id": self.agent_id };
    }
}

walker create_interview_session {
    has str interview_type;
    has str job_description;
    has str duration;
    has bool file_uploaded;
    has str file_name;
    has str file_data;

    obj __specs__ { static has bool auth = False; }

    def save_file(session_id: str, file_name: str, file_data: str) {
        UPLOAD_DIR = os.path.join("uploads", session_id);
        if not os.path.exists(UPLOAD_DIR) { os.makedirs(UPLOAD_DIR); }

        file_path = os.path.join(UPLOAD_DIR, file_name);
        data = base64.b64decode(file_data.encode("utf-8"));
        with open(file_path, "wb") as f { f.write(data); }

        return { "status": "uploaded", "file_path": file_path };
    }

    can save_interview_data with `root entry {
        session_id = str(uuid.uuid4());
        print(f"session: {session_id} created");

        file_path = "";
        if self.file_uploaded {
            saved = self.save_file(session_id, self.file_name, self.file_data);
            file_path = (("file_path" in saved) ? saved["file_path"] : "");
        }

        new_session = Session(session_id, self.interview_type, self.job_description, self.duration, self.file_uploaded, file_path);
        root ++> new_session;
        visit new_session;
    }
}

/* =========================
   Agent endpoints (Q/A/Feedback/Voice)
   ========================= */

/* --- Question Generation --- */
walker GenerateQuestions {
    """
    Generate interview questions for a job description.
    Returns JSON: non-technical list, technical list, and a voice-ready semantic prompt.
    """
    param str job_desc;
    param bool include_tech = true;
    param int nontech_n = 5;
    param int tech_n = 3;

    can entry {
        nontech = gen_nontech_questions(job_desc, nontech_n);
        tech = (include_tech ? gen_tech_questions(job_desc, tech_n) : []);

        prompt = make_voice_prompt(
            "You are an interviewer. Ask one question at a time and wait for a response.",
            [ { "text": q, "type": "nontech" } for q in nontech ] +
            [ { "text": q, "type": "tech" } for q in tech ]
        );

        report {
            "nontech": nontech,
            "tech": tech,
            "semantic_prompt": prompt
        };
    }
}

/* --- Answer Evaluation (non-coding now; coding TBD) --- */
walker EvaluateAnswer {
    """
    Evaluate a single answer.
    For non-coding questions: returns { score: float, rationale: str } via LLM.
    For coding questions: placeholder until a sandbox is attached.
    """
    param str question;
    param str qtype;     // 'nontech' | 'tech' | 'coding'
    param str answer;

    can entry {
        if qtype == "coding" {
            report { "score": 0.0, "rationale": "Coding evaluator not implemented yet." };
        } else {
            res = eval_nontech_answer(question, answer);
            report res;
        }
    }
}

/* --- Feedback Compilation --- */
walker CompileFeedback {
    """
    Combine per-question scores into a session summary and tips.
    per_question: list of { 'q': str, 'qtype': str, 'score': float, 'rationale': str }
    """
    param list[dict] per_question;

    can entry {
        avg = 0.0;
        if len(per_question) > 0 {
            total = 0.0;
            for item in per_question {
                sc = 0.0;
                if "score" in item { sc = item["score"]; }
                total += sc;
            }
            avg = total / len(per_question);
        }

        payload = { "average": avg, "items": per_question };
        fb = summarize_feedback(payload);

        report {
            "average": avg,
            "feedback": fb   // { "summary": str, "tips": list[str] }
        };
    }
}

/* --- Build a voice prompt directly --- */
walker CreateVoicePrompt {
    """
    Accepts intro text and an array of question dicts and returns a VoicePrompt object.
    Useful if the frontend creates/edits question lists and needs a voice-ready payload.
    """
    param str intro;
    param list[dict] questions;  // [{ "text": str, "type": "nontech"|"tech", "hint": str|None }]

    can entry {
        report make_voice_prompt(intro, questions);
    }
}

/* =========================
   Text-first RAG endpoints (uses RAGTEXT from rag_text.jac)
   ========================= */

/* Add a job post / resume / snippet as raw text */
walker RagAddText {
    """
    Store raw text into the RAG store under a source_id (e.g., 'jd:backend-123' or 'resume:alice').
    """
    param str source_id;
    param str text;

    can entry {
        RAGTEXT.add_text(source_id, text);
        report { "ok": true, "source_id": source_id, "chunks_added": true };
    }
}

/* Quick human-readable retrieval */
walker RagSearch {
    param str query;
    param int k = 5;

    can entry {
        summary = RAGTEXT.search(query, k);
        report { "summary": summary };
    }
}

/* Grounded answer using local text chunks (no extra HTTP service) */
walker RAGAnswerLocal {
    param str query;
    param int k = 5;

    can entry {
        pairs = RAGTEXT.get_pairs(query, k);
        snippets = [];
        sources = [];
        for p in pairs {
            doc = p[0];
            snippets.append(doc.page_content);
            if "source" in doc.metadata { sources.append(doc.metadata["source"]); }
        }
        ans = answer_with_context(query, snippets);
        report {
            "answer": (("answer" in ans) ? ans["answer"] : ""),
            "sources": sources
        };
    }
}
