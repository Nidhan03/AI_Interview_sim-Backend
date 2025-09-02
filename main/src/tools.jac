import os;
import from mtllm.llm { Model };
import from langchain_openai { OpenAIEmbeddings };
import from langchain_community.document_loaders { PyPDFLoader };
import from langchain_text_splitters { RecursiveCharacterTextSplitter };
import from langchain.schema.document { Document };
import from langchain_chroma { Chroma };

glob llm = Model(model_name="openai/gpt-4o-mini");

obj RagEngine {
    has file_path: str = "data/docs";
    has chroma_path: str = "data/chroma";

    def postinit {
        if not os.path.exists(self.file_path) {
            os.makedirs(self.file_path);
        }
        if not os.path.exists(self.chroma_path) {
            os.makedirs(self.chroma_path);
        }
    }

    def load_document(file_path: str) {
        loader = PyPDFLoader(file_path);
        return loader.load();
    }

    def add_file(file_path: str) {
        documents = self.load_document(file_path);
        chunks = self.split_documents(documents);
        self.add_to_chroma(chunks);
    }

    def split_documents(documents: list[Document]) {
        text_splitter = RecursiveCharacterTextSplitter(
            chunk_size=800,
            chunk_overlap=80,
            length_function=len,
            is_separator_regex=False
        );
        return text_splitter.split_documents(documents);
    }

    def get_embedding_function {
        return OpenAIEmbeddings(model="text-embedding-3-small");
    }

    def add_chunk_id(chunks: list[Document]) {
        last_page_id = None;
        current_chunk_index = 0;

        for chunk in chunks {
            source = chunk.metadata.get("source");
            page = chunk.metadata.get("page");
            current_page_id = f"{source}:{page}";

            if current_page_id == last_page_id {
                current_chunk_index += 1;
            } else {
                current_chunk_index = 0;
            }

            chunk_id = f"{current_page_id}:{current_chunk_index}";
            last_page_id = current_page_id;

            chunk.metadata["id"] = chunk_id;
        }
        return chunks;
    }

    def add_to_chroma(chunks: list[Document]) {
        db = Chroma(
            persist_directory=self.chroma_path,
            embedding_function=self.get_embedding_function()
        );

        db.reset_collection();
        chunks_with_ids = self.add_chunk_id(chunks);
        new_chunk_ids = [chunk.metadata["id"] for chunk in chunks_with_ids];

        std.out("Replacing existing database with new file");
        db.add_documents(chunks_with_ids, ids=new_chunk_ids);
    }

    def get_from_chroma(query: str, chunck_nos: int=5) {
        db = Chroma(
            persist_directory=self.chroma_path,
            embedding_function=self.get_embedding_function()
        );
        results = db.similarity_search_with_score(query, k=chunck_nos);
        return results;
    }

    def search(query: str, chunck_nos: int=5) {
        results = self.get_from_chroma(query=query, chunck_nos=chunck_nos);
        summary = "";
        for (doc, score) in results {
            page = doc.metadata.get("page");
            source = doc.metadata.get("source");
            chunk_txt = doc.page_content[:400].replace("\n", " ");
            summary += f"{source} page {page} (score={score}): {chunk_txt}\n";
        }
        return summary;
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
You are an interview coach. Write a concise overall feedback report for an interview session.

Interview Type: {interview_type}
Job Description: {job_description}

Conversation Transcript:
{conversation}

Coding Problem:
{coding_problem}

Candidate's Solution:
{coding_solution}

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

