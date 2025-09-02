import os;
import from mtllm.llm { Model };
import from langchain_openai { OpenAIEmbeddings };
import from langchain_community.document_loaders { PyPDFLoader };
import from langchain_text_splitters { RecursiveCharacterTextSplitter };
import from langchain.schema.document { Document };
import from langchain_chroma { Chroma };

glob llm = Model(model_name="openai/gpt-4o-mini");

import json;
import requests;

obj RagEngine {
    has base_url: str = "http://127.0.0.1:7001";

    # Upload a file to the Python RAG service (/ingest/file)
    def add_file(fp: str) {
        url = f"{self.base_url}/ingest/file";
        try {
            with open(fp, "rb") as f {
                # multipart/form-data upload
                # Jac uses Python's requests under the hood, same signature
                files = {"file": (fp.split(os.sep)[-1], f, "application/octet-stream")};
                resp = requests.post(url, files=files);
            }
            if resp.status_code != 200 {
                std.err(f"[RAG] add_file failed {resp.status_code}: {resp.text}");
            } else {
                std.out(f"[RAG] add_file ok: {resp.text}");
            }
        } except Exception as e {
            std.err(f"[RAG] add_file exception: {e}");
        }
    }

    # Query the RAG service (/query) and return a short, readable summary string
    def search(query: str, k: int=5) -> str {
        url = f"{self.base_url}/query";
        try {
            resp = requests.post(url, json={"query": query, "k": k});
            if resp.status_code != 200 {
                return f"[RAG] search failed {resp.status_code}: {resp.text}";
            }
            data = resp.json();
            results = data.get("results", []);
            if len(results) == 0 { return "No relevant context found."; }

            out = "";
            for r in results {
                meta = r.get("metadata") or {};
                source = meta.get("source");
                page   = meta.get("page");
                text   = (r.get("page_content") or "")[:400].replace("\n", " ");
                out += f"{source} page {page}: {text}\n";
            }
            return out;
        } except Exception as e {
            return f"[RAG] search exception: {e}";
        }
    }
}


/*
Reads the interview agent prompt format from `prompt_format.txt`.
The format includes placeholders that can only be replaced.
*/
def read_prompt_format() -> str {
    try {
        with open("prompt_format.txt", "r") as f {
            return f.read();
        }
    } except Exception as e {
        return f"Error occurred: {e}";
    }
}

/*
Generate a list of interview questions based on the interview_type and the job_description.
*/
def get_interview_questions(interview_type: str, job_description: str) -> list[str] by llm();

/*
Generate a very simple Python coding problem tailored to the job description.
*/
def generate_coding_problem(job_description: str) -> dict[str, str] by llm();

/*
Builds the full prompt for the interview agent by combining the
format file + generated questions + candidate summary + coding problem.
*/
def generate_interview_agent_prompt(
    duration: str,
    interview_type: str,
    job_description: str,
    interviewee_cv_data: str,
    coding_problem: dict[str, str]
) -> str by llm(tools=[read_prompt_format, get_interview_questions]);

/*
Summarize overall feedback into a concise report.
*/
def summarize_overall_feedback(
    nontech_evals: list[str],
    tech_evals: list[str],
    code_evals: list[str]
) -> str {
    nt = "\n- ".join(nontech_evals) if len(nontech_evals) > 0 else "None collected.";
    tt = "\n- ".join(tech_evals)    if len(tech_evals)    > 0 else "None collected.";
    cc = "\n- ".join(code_evals)    if len(code_evals)    > 0 else "Code feedback pending.";

    prompt = f"""
You are an interview coach. Write a concise overall feedback report that aggregates prior per-question evaluations.

Non-Technical Feedback:
- {nt}

Technical Feedback:
- {tt}

Code-Answer Feedback:
- {cc}

Requirements:
- Start with an Overall Score out of 10 (one decimal).
- Then 3–5 bullet Strengths.
- Then 3–5 bullet Improvements.
- One paragraph of Actionable Next Steps.
- Keep it under 250 words.
Return plain text (no JSON).
""";

    out = llm.complete(prompt);
    return out;
}
