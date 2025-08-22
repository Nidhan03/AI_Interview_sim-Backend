# pip install pymongo tiktoken openai python-dotenv pypdf
import os, json
from pymongo import MongoClient
from dotenv import load_dotenv
from pypdf import PdfReader
import tiktoken
from openai import OpenAI

load_dotenv()
MONGO_URI = os.getenv("MONGO_URI")
DB = os.getenv("MONGO_DB", "interviewkb")
COLL = os.getenv("MONGO_COLL", "kb_chunks")
EMBED_MODEL = os.getenv("EMBED_MODEL", "text-embedding-3-small")  # 1536 dims
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))

mongo = MongoClient(MONGO_URI)[DB][COLL]
enc = tiktoken.get_encoding("cl100k_base")

def chunk_text(text, max_tokens=500, overlap=100):
    toks = enc.encode(text)
    chunks = []
    i = 0
    while i < len(toks):
        piece = enc.decode(toks[i:i+max_tokens])
        chunks.append(piece)
        i += max_tokens - overlap
    return chunks

def embed(texts):
    # batch for performance
    resp = client.embeddings.create(model=EMBED_MODEL, input=texts)
    return [d.embedding for d in resp.data]

def ingest_pdf(path, doc_id):
    reader = PdfReader(path)
    full = "\n".join(page.extract_text() or "" for page in reader.pages)
    chunks = chunk_text(full)
    embs = embed(chunks)
    docs = [{"doc_id": doc_id, "chunk": c, "embedding": e, "meta": {"source":"pdf","file": os.path.basename(path)}} for c,e in zip(chunks, embs)]
    if docs:
        mongo.insert_many(docs)

if __name__ == "__main__":
    # Example: point to a folder of PDFs or text files
    ingest_pdf("data/backend_role.pdf", "backend_role_pdf")
