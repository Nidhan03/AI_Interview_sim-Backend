# server.jac — exposes entry-point walkers for the backend API
# These walkers call the LLM tools defined in main/src/tools.jac

# --- Imports ---
import from tools {
    gen_nontech_questions,
    gen_tech_questions,
    eval_nontech_answer,
    summarize_feedback,
    make_voice_prompt
};

# --- Question Generation ---
walker GenerateQuestions:
    """
    Generate interview questions for a job description.
    Returns a JSON with non-technical questions, technical questions, and a voice-ready semantic prompt.
    """
    param str job_desc;
    param bool include_tech = true;
    param int nontech_n = 5;
    param int tech_n = 3;

    can entry:
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

# --- Answer Evaluation (non-coding now; coding stub is T.B.D.) ---
walker EvaluateAnswer:
    """
    Evaluate a single answer.
    For non-coding questions: returns { score: float, rationale: str } via LLM.
    For coding questions: placeholder until a sandbox is attached.
    """
    param str question;
    param str qtype;     # 'nontech' | 'tech' | 'coding'
    param str answer;

    can entry:
        if qtype == "coding":
            report { "score": 0.0, "rationale": "Coding evaluator not implemented yet." };
        else:
            res = eval_nontech_answer(question, answer);
            report res;

# --- Feedback Compilation across all questions ---
walker CompileFeedback:
    """
    Combine per-question scores into a session summary and tips.
    per_question: list of { 'q': str, 'qtype': str, 'score': float, 'rationale': str }
    """
    param list[dict] per_question;

    can entry:
        avg = 0.0;
        if len(per_question) > 0:
            total = 0.0;
            for item in per_question:
                sc = 0.0;
                if "score" in item:
                    sc = item["score"];
                total += sc;
            avg = total / len(per_question);

        payload = { "average": avg, "items": per_question };
        fb = summarize_feedback(payload);

        report {
            "average": avg,
            "feedback": fb  # expected { "summary": str, "tips": list[str] }
        };

# --- Optional: simple utility to build a voice prompt directly ---
walker CreateVoicePrompt:
    """
    Accepts intro text and an array of question dicts and returns a VoicePrompt object.
    Useful if the frontend creates or edits question lists and just needs a voice-ready payload.
    """
    param str intro;
    param list[dict] questions;  # [{ "text": str, "type": "nontech"|"tech", "hint": str|None }]

    can entry:
        report make_voice_prompt(intro, questions);

import from tools { answer_with_context };

walker RAGAnswer:
    """
    Retrieval-Augmented answer. Fetches top-k chunks from the RAG service, then answers using those snippets.
    """
    param str query;
    param int k = 5;
    param str rag_base = (ENV.RAG_BASE if ENV.RAG_BASE else "http://localhost:8081");

    can entry:
        import requests;
        url = rag_base + "/search?q=" + query + "&k=" + str(k);
        resp = requests.get(url);
        data = resp.json();
        snippets = [];
        if "hits" in data:
            for h in data["hits"]:
                if "chunk" in h:
                    snippets.append(h["chunk"]);
        grounded = answer_with_context(query, snippets);
        report grounded;

