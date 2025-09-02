import from mtllm.llm {Model}
import os;
import from langchain_community.document_loaders {PyPDFLoader}
import from langchain_text_splitters {RecursiveCharacterTextSplitter}
import from langchain.schema.document {Document}
import from langchain_openai {OpenAIEmbeddings}
import from langchain_chroma {Chroma}


glob llm = Model(model_name="gemini/gemini-2.0-flash");

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
        embeddings = OpenAIEmbeddings();
        return embeddings;
    }

    def add_chunk_id(chunks: list[Document]) {
        last_page_id = None;
        current_chunk_index = 0;

        for chunk in chunks {
            source = chunk.metadata.get('source');
            page = chunk.metadata.get('page');
            current_page_id = f'{source}:{page}';

            if current_page_id == last_page_id {
                current_chunk_index += 1;
            } else {
                current_chunk_index = 0;
            }

            chunk_id = f'{current_page_id}:{current_chunk_index}';
            last_page_id = current_page_id;

            chunk.metadata['id'] = chunk_id;
        }

        return chunks;
    }

    def add_to_chroma(chunks: list[Document]) {
        db = Chroma(
            persist_directory=self.chroma_path,
            embedding_function=self.get_embedding_function()
        );

        # wipe and re-initialize the collection in one step
        db.reset_collection();

        # add fresh docs
        chunks_with_ids = self.add_chunk_id(chunks);
        new_chunk_ids = [chunk.metadata['id'] for chunk in chunks_with_ids];

        print('replacing existing database with new file');
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
        results = self.get_from_chroma(
            query=query, 
            chunck_nos=chunck_nos);
        summary = "";
        for (doc, score) in results {
            page = doc.metadata.get('page');
            source = doc.metadata.get('source');
            chunk_txt = doc.page_content[:400].replace("\n"," ");
            summary += f"{source} page {page} (score={score}): {chunk_txt}\n";
        }
        return summary;
    }
}

"""
Reads the interview agent prompt format from `prompt_format.txt`.
The format includes placeholders that can only be replaced.
Returns:
    str: The prompt format.
"""
def read_prompt_format() -> str{
    try{
        with open("prompt_format.txt","r") as f{
            return f.read();
        }
    }except Exception as e{
        return f"Error occurred: {e}";
    }
}

"""
Generate a list of interview questions based on the interview_type and the job_description.

Returns:
    list[str]: A list containing interview questions
"""
def get_interview_questions(interview_type: str, job_description: str) -> list[str] by llm();

"""
Generate a very simple Python coding problem suitable for a technical interview, tailored to the given job description.

The problem must include:
- A clear and concise problem statement
- Formal input and output specifications
- Explicit constraints and assumptions
- Example test cases with expected outputs

Returns:
    dict: A structured dictionary containing the following keys:
        - problem_statement (str): The full problem description.
        - input_format (str): Specification of the expected input.
        - output_format (str): Specification of the expected output.
        - constraints (str): Defined limits and rules for the problem.
        - example_test_cases (str): Sample inputs with corresponding outputs.
"""
def generate_coding_problem(job_description: str) -> dict[str,str] by llm();



"""
Generate a structured prompt for an interview agent to conduct a realistic interview simulation.

The process involves two steps:
1. Use the prompt format retrieval tool to obtain the standardized interview prompt structure.
2. Use the interview questions tool to gather domain-specific questions aligned with the job description, and insert them into the structure together with a concise candidate CV summary.

All placeholders in the structure should be filled appropriately:
- Replace {interview_questions} with the retrieved domain-specific questions.
- Populate the remaining placeholders with the provided parameters and the candidate’s summarized CV.

Returns:
    str: A fully formatted interview prompt that integrates the standardized structure, candidate details, and tailored interview questions, ready for use by the interview agent.
"""
def generate_interview_agent_prompt(duration: str, interview_type: str, job_description: str, interviewee_cv_data: str, coding_problem: dict[str,str]) -> str by llm(tools=[read_prompt_format, get_interview_questions]);

