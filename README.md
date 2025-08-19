# AI Interview Simulator

The AI Interview Simulator is an AI-powered platform that helps users prepare for job interviews through realistic and interactive simulations. Built as a multi-agent system, it supports multiple interview types and provides personalized questions, timed challenges, and feedback to help users improve their performance.

## Core Features

- Personalized interview sessions based on job roles and types
- Smart question generation across behavioral, technical, HR, and case study domains
- Interactive technical challenges including coding and system design
- Automated evaluation and feedback generation
- Multi-agent architecture for modular and scalable interview workflows

## Getting Started

### Backend Setup

1. **Clone the repo**

```bash
git clone https://github.com/Nidhan03/AI_Interview_sim-Backend.git
cd AI_Interview_sim-Backend
```

2. **Install dependencies**

```bash
pip install -r requirements.txt
```

3. **Configure environment**

Copy `.env.example` to `.env` and set your ElevenLabs API credentials:

```env
ELEVENLABS_API_KEY=...
```

3. **Run the backend**

```bash
jac serve main/src/server.jac
```

4. **Run the frontend**

```bash
jac streamlit main/frontend/streamlit_app.jac
```

## 📄 License

This project is licensed under a proprietary license.
