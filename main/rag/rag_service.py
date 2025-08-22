# pip install fastapi uvicorn pymongo openai python-dotenv
import os
from fastapi import FastAPI, Query
from pydantic import BaseModel
from pymongo import MongoClient
from dotenv import load_dotenv
from openai import OpenAI

load_dotenv()
MONGO_URI = os.getenv("MONGO_URI")
DB = os.getenv("MONGO_DB", "interviewkb")
COLL = os.getenv("MONGO_COLL", "kb_chunks")
EMBED_MODEL = os.getenv("EMBED_MODEL", "text-embedding-3-small")

mongo = MongoClient(MONGO_URI)[DB][COLL]
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
app = FastAPI(title="RAG Retrieval API")

class Hit(BaseModel):
    chunk: str
    score: float
    meta: dict | None = None

class SearchResponse(BaseModel):
    hits: list[Hit]

def embed_query(q: str):
    return client.embeddings.create(model=EMBED_MODEL, input=[q]).data[0].embedding

@app.get("/search", response_model=SearchResponse)
def search(q: str = Query(...), k: int = 5):
    qvec = embed_query(q)
    # Atlas Vector Search $vectorSearch (requires proper index created)
    pipeline = [{
      "$vectorSearch": {
        "index": "vector_index",          # name of your index
        "path": "embedding",
        "queryVector": qvec,
        "numCandidates": 200,
        "limit": k
      }
    }, {
      "$project": { "chunk": 1, "meta": 1, "_id": 0, "score": { "$meta": "vectorSearchScore" } }
    }]
    results = list(mongo.aggregate(pipeline))
    return {"hits": [{"chunk": r["chunk"], "score": float(r["score"]), "meta": r.get("meta")} for r in results]}

# Run with: uvicorn rag_service:app --reload --port 8081
