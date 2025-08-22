import from langchain_text_splitters { RecursiveCharacterTextSplitter };
import from langchain_openai { OpenAIEmbeddings };
import from langchain_chroma { Chroma };

/* Text-first RAG engine:
   - add_text(source_id, text): chunk & store text with embeddings
   - search(query, k): retrieve top-k chunks
   - get_pairs(query, k): raw (Document, score) pairs for LLM grounding
*/
obj RagTextEngine {
    has str chroma_path = "chroma";

    def get_embedding_function {
        // Requires OPENAI_API_KEY in environment
        emb = OpenAIEmbeddings();
        return emb;
    }

    def get_splitter {
        return RecursiveCharacterTextSplitter(
            chunk_size=800,
            chunk_overlap=100,
            length_function=len,
            is_separator_regex=false
        );
    }

    def add_text(source_id: str, text: str) {
        splitter = self.get_splitter();
        chunks = splitter.split_text(text);

        // Build stable ids + metadatas
        ids = [];
        metas = [];
        i = 0;
        while i < len(chunks) {
            ids.append(f"{source_id}:{i}");
            metas.append({ "source": source_id, "idx": i });
            i += 1;
        }

        // Persist to Chroma
        db = Chroma(persist_directory=self.chroma_path, embedding_function=self.get_embedding_function());
        // add_texts(texts, metadatas=None, ids=None)
        db.add_texts(chunks, metas, ids);
    }

    def get_pairs(query: str, k: int = 5) {
        db = Chroma(persist_directory=self.chroma_path, embedding_function=self.get_embedding_function());
        // returns [(Document, score), ...]
        results = db.similarity_search_with_score(query, k=k);
        return results;
    }

    def search(query: str, k: int = 5) -> str {
        pairs = self.get_pairs(query, k);
        summary = "";
        for p in pairs {
            doc = p[0];
            score = p[1];
            src = (("source" in doc.metadata) ? doc.metadata["source"] : "");
            snip = doc.page_content[:400];
            summary += f"{src} (score={score}): {snip}\n";
        }
        return summary;
    }
}

/* Singleton usable from walkers */
glob RAGTEXT = RagTextEngine();

