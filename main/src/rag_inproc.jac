import os;
import requests;

import from langchain_community.document_loaders { PyPDFDirectoryLoader, PyPDFLoader };
import from langchain_text_splitters { RecursiveCharacterTextSplitter };
import from langchain_openai { OpenAIEmbeddings };
import from langchain_chroma { Chroma };

glob SERPER_API_KEY: str = os.getenv("SERPER_API_KEY", "");

obj RagEngine {
    has str file_path = "docs";
    has str chroma_path = "chroma";

    def postinit {
        if not os.path.exists(self.file_path) {
            os.makedirs(self.file_path);
        }
        // Optional auto-load on startup (comment out if you don't want this)
        documents = self.load_documents();
        chunks = self.split_documents(documents);
        self.add_to_chroma(chunks);
    }

    def load_documents -> list {
        loader = PyPDFDirectoryLoader(self.file_path);
        return loader.load();
    }

    def load_document(file_path: str) -> list {
        loader = PyPDFLoader(file_path);
        return loader.load();
    }

    def add_file(file_path: str) {
        documents = self.load_document(file_path);
        chunks = self.split_documents(documents);
        self.add_to_chroma(chunks);
    }

    def split_documents(documents: list) -> list {
        splitter = RecursiveCharacterTextSplitter(
            chunk_size=800,
            chunk_overlap=80,
            length_function=len,
            is_separator_regex=false
        );
        return splitter.split_documents(documents);
    }

    def get_embedding_function {
        // Uses OPENAI_API_KEY from env
        emb = OpenAIEmbeddings();
        return emb;
    }

    def add_chunk_id(chunks: list) -> list {
        last_page_id = None;
        current_chunk_index = 0;
        for chunk in chunks {
            source = (("source" in chunk.metadata) ? chunk.metadata["source"] : "");
            page = (("page" in chunk.metadata) ? chunk.metadata["page"] : 0);
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

    def add_to_chroma(chunks: list) {
        db = Chroma(persist_directory=self.chroma_path, embedding_function=self.get_embedding_function());
        chunks_with_ids = self.add_chunk_id(chunks);

        existing = db.get(include=[]);
        existing_ids = (("ids" in existing) ? set(existing["ids"]) : set());

        new_chunks = [];
        for c in chunks_with_ids {
            cid = (("id" in c.metadata) ? c.metadata["id"] : None);
            if cid and cid not in existing_ids {
                new_chunks.append(c);
            }
        }

        if len(new_chunks) > 0 {
            print("adding new documents");
            new_ids = [nc.metadata["id"] for nc in new_chunks];
            db.add_documents(new_chunks, ids=new_ids);
        } else {
            print("no new documents to add");
        }
    }

    def get_from_chroma(query: str, k: int = 5) -> list {
        db = Chroma(persist_directory=self.chroma_path, embedding_function=self.get_embedding_function());
        // returns list of (Document, score)
        results = db.similarity_search_with_score(query, k=k);
        return results;
    }

    def search(query: str, k: int = 5) -> str {
        results = self.get_from_chroma(query=query, k=k);
        summary = "";
        for pair in results {
            doc = pair[0];
            score = pair[1];
            page = (("page" in doc.metadata) ? doc.metadata["page"] : 0);
            source = (("source" in doc.metadata) ? doc.metadata["source"] : "");
            chunk_txt = doc.page_content[:400];
            summary += f"{source} page {page} (score={score}): {chunk_txt}\n";
        }
        return summary;
    }
}

// Optional web search helper (Serper)
obj WebSearch {
    has str api_key = SERPER_API_KEY;
    has str base_url = "https://google.serper.dev/search";

    def search(query: str) -> str {
        headers = { "X-API-KEY": self.api_key, "Content-Type": "application/json" };
        payload = { "q": query };
        resp = requests.post(self.base_url, headers=headers, json=payload);
        if resp.status_code == 200 {
            data = resp.json();
            summary = "";
            results = (isinstance(data, dict) ? (("organic" in data) ? data["organic"] : []) : []);
            for r in results[:3] {
                title = (("title" in r) ? r["title"] : "");
                link = (("link" in r) ? r["link"] : "");
                snippet = (("snippet" in r) ? r["snippet"] : "");
                summary += f"{title}: {link}\n";
                if snippet { summary += f"{snippet}\n"; }
            }
            return summary;
        }
        return f"Serper request failed: {resp.status_code}";
    }
}

// Make a global engine instance usable from walkers
glob RAG = RagEngine();
