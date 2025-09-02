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


def generate_overall_feedback_report(
    interview_type: str,
    job_description: str,
    conversation: str,
    coding_problem: str,
    coding_solution: str
) -> str {
    prompt = f"""
You are an expert interview coach. Produce a concise, professional feedback report that
SYNTHESIZES insights from the materials below. Do NOT restate the job type or description
verbatim; USE them to weight what matters. Ground comments in the candidate's conversation
and (if present) their code.

Context to use (do not echo verbatim):
- Interview type: {interview_type}
- Job description: {job_description}
- Conversation (transcript/extracts): 
{conversation}

- Coding problem (if any; treat as context): 
{coding_problem}

- Candidate's coding solution (if any; analyze it): 
{coding_solution}

Requirements for the output (plain text, no JSON, no headings like 'Interview Type'):
1) Start with: "Overall Score: X.Y/10" (one decimal).
2) Then **Strengths** — 3–5 bullets. Tie each bullet to evidence from the conversation or code.
   Prefer competencies relevant to the role implied by the job description and interview type
   (e.g., system design, data structures, communication, product sense, estimation).
3) Then **Improvements** — 3–5 bullets. Be specific and role-weighted. Reference concrete moments
   from the conversation or typical expectations for this role when helpful.
4) If code is present, include one compact **Code Assessment** paragraph covering:
   - correctness vs. the problem requirements
   - time/space complexity at a high level
   - design/clarity (structure, naming, modularity)
   - robustness (edge cases, tests)
   If no code was submitted, write: "Code Assessment: Not applicable."
5) End with **Next Steps** — 1 short paragraph of actionable, prioritized practice items aligned
   to the role (e.g., "practice X patterns", "review Y topics", "prepare Z examples").
6) Keep the entire report under 230 words. Use a neutral, professional tone. Avoid repeating
   the job description verbatim; instead, let it guide which skills matter most.

Now write the final report.
""";

    out = llm.complete(prompt);
    return out;
}

