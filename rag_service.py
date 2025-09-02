# rag_service.py
import os
from fastapi import FastAPI, UploadFile, File, Form
from pydantic import BaseModel
from typing import List
from langchain_openai import OpenAIEmbeddings
from langchain.text_splitter import RecursiveCharacterTextSplitter
from langchain_community.vectorstores import Chroma
from langchain_community.document_loaders import PyPDFLoader, TextLoader
from langchain.schema import Document

PERSIST_DIR = os.getenv("CHROMA_DIR", "data/chroma")
EMBED_MODEL = os.getenv("EMBED_MODEL", "text-embedding-3-small")

app = FastAPI()
emb = OpenAIEmbeddings(model=EMBED_MODEL)
splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=150)

def get_vs():
    return Chroma(persist_directory=PERSIST_DIR, embedding_function=emb)

@app.get("/health")
def health():
    return {"status": "ok", "persist_dir": PERSIST_DIR, "embed_model": EMBED_MODEL}

@app.post("/ingest/file")
async def ingest_file(file: UploadFile = File(...)):
    path = f"/tmp/{file.filename}"
    with open(path, "wb") as f:
        f.write(await file.read())

    if file.filename.lower().endswith(".pdf"):
        docs = PyPDFLoader(path).load()
    else:
        docs = TextLoader(path, encoding="utf-8").load()
    chunks = splitter.split_documents(docs)
    vs = get_vs()
    vs.add_documents(chunks)
    return {"added_chunks": len(chunks)}

class QueryReq(BaseModel):
    query: str
    k: int = 5

@app.post("/query")
def query(req: QueryReq):
    vs = get_vs()
    docs = vs.similarity_search(req.query, k=req.k)
    return {"results": [{"page_content": d.page_content, "metadata": d.metadata} for d in docs]}
