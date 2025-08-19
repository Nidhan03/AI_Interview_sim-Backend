import from mtllm.llm { Model }

# Configure the LLM provider/model. Override via environment variable MODEL_NAME if desired.
glob llm = Model(model_name = (ENV.MODEL_NAME if ENV.MODEL_NAME else "gpt-4o"));

# ---------------------------------------------------------------------
# AI TOOLING (LLM-backed). These are pure functions you can call in walkers.
# Keep them small and composable; walkers orchestrate higher-level flows.
# ---------------------------------------------------------------------

"""
Generate N behavioral/HR/situational/case-style questions tailored to a job description.
Return: Python list[str] of exactly n items.
"""
def gen_nontech_questions(job_desc: str, n: int = 5) -> list[str] by llm();

"""
Generate N technical (non-coding) interview questions tailored to a job description.
Return: Python list[str] of exactly n items.
"""
def gen_tech_questions(job_desc: str, n: int = 3) -> list[str] by llm();

"""
Evaluate a non-technical answer on clarity, relevance, and structure (e.g., STAR).
Return JSON with keys: { "score": float (0..5), "rationale": str }.
"""
def eval_nontech_answer(question: str, answer: str) -> dict by llm();

"""
Summarize an interview into a short narrative and 3 actionable tips.
Input: summary_blob may include averages, per-question scores, and notes.
Return: { "summary": str, "tips": list[str] }
"""
def summarize_feedback(summary_blob: dict) -> dict by llm();

# ---------------------------------------------------------------------
# Voice prompt helper (for ElevenLabs or any TTS pipeline)
# ---------------------------------------------------------------------

obj VoicePrompt:
    has str intro
    has list[dict] questions    # [{ "text": str, "type": "nontech"|"tech", "hint": str|None }]

def make_voice_prompt(intro: str, questions: list[dict]) -> VoicePrompt:
    return VoicePrompt(intro=intro, questions=questions)


"""
Given a user query and retrieved snippets, produce a grounded answer.
Return: { "answer": str, "sources": list[str] }
"""
def answer_with_context(query: str, context_snippets: list[str]) -> dict by llm();

