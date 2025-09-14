import os;
import from byllm.llm {Model}
import base64;
import from code_analyzer {build_python_context_graph}
import requests;
import from tools {generate_coding_problem,generate_interview_agent_prompt, RagEngine, generate_overall_feedback_report }

glob rag_engine:RagEngine = RagEngine();

glob llm = Model(model_name="gemini/gemini-2.0-flash");


enum TaskType{
    CreateInterview = "CreateInterview",
    EndInterview = "EndInterview",
}

node Task{
    has task_type: TaskType;
}

node CreateInterview(Task){
    has task_type: TaskType = TaskType.CreateInterview;
    has file_path: str = "";
    has agent_id: str = "";
    has tool_id: str = "";
  
    def save_file(session_id: str, file_name: str, file_data: str);

    can create_interview_agent with manage_interview_session entry;
}

node EndInterview(Task){
    has task_type: TaskType = TaskType.EndInterview;
    has feedback: str = "";

    can get_interview_results with manage_interview_session entry;
}

node Session{

    """Decide the next step in the interview process based on the session history"""
    def decide_next_step(session_history: list[dict]) -> TaskType by llm(verbose=True,method="ReAct");

    can route with entry{
        next_task = self.decide_next_step(visitor.session_history);
        print(f"Routing to {next_task}");
        visit[-->](`?Task)(?task_type==next_task);
    }

}

walker manage_interview_session{
    has session_history: list[dict];
    has interview_type: str;
    has job_description:str;
    has duration: str;
    has file_uploaded: bool;
    has file_name: str;
    has file_data: str;
    has conversation_history: list[dict];  #For feedback use only
    has coding_problem: dict[str,str];
    has coding_solution: str;              #For feedback use only

    obj __specs__ {
        static has auth: bool = False;
    }
    
    can save_interview_data with `root entry{
        visit [-->](`?Session);
    }
}


with entry{

    new_session = root ++> Session();
    if new_session{
        print("New Session node Created");
    }
    create_interview = new_session ++> CreateInterview();
    if create_interview{
        print("CreateInterview node Created");
    }
    new_session ++> EndInterview();
    if EndInterview{
        print("EndInterview node Created");
    }
    
}
import datetime;

/* Simple per-session metrics stored in memory */
obj Metrics {
    has int q_asked = 0;
    has float total_score = 0.0;
    has int answers = 0;
    has float avg_score = 0.0;
    has str started_at = "";
}

/* Global in-memory store: session_id -> Metrics */
glob METRICS = {};

/* Initialize metrics for a session (idempotent) */
walker InitMetrics {
    param str session_id;

    can entry {
        if not (session_id in METRICS) {
            m = Metrics();
            m.started_at = datetime.datetime.utcnow().isoformat() + "Z";
            METRICS[session_id] = m;
        }
        report { "ok": true, "metrics": METRICS[session_id] };
    }
}

/* Increment 'questions asked' counter */
walker BumpQuestionCount {
    param str session_id;

    can entry {
        if not (session_id in METRICS) { visit InitMetrics(session_id=session_id); }
        METRICS[session_id].q_asked += 1;
        report { "q_asked": METRICS[session_id].q_asked };
    }
}

/* Record a score for the most recent answer (0..5 or 0..10—your choice) */
walker RecordAnswerScore {
    param str session_id;
    param float score;

    can entry {
        if not (session_id in METRICS) { visit InitMetrics(session_id=session_id); }
        m = METRICS[session_id];
        m.total_score += score;
        m.answers += 1;
        m.avg_score = (m.answers > 0 ? (m.total_score / m.answers) : 0.0);
        report { "answers": m.answers, "avg_score": m.avg_score, "total_score": m.total_score };
    }
}

/* Read current metrics snapshot */
walker GetMetrics {
    param str session_id;

    can entry {
        if not (session_id in METRICS) { visit InitMetrics(session_id=session_id); }
        m = METRICS[session_id];
        report {
            "session_id": session_id,
            "started_at": m.started_at,
            "q_asked": m.q_asked,
            "answers": m.answers,
            "avg_score": m.avg_score,
            "total_score": m.total_score
        };
    }
}

/* Clear metrics for a session (e.g., at end) */
walker ResetMetrics {
    param str session_id;

    can entry {
        if session_id in METRICS { del METRICS[session_id]; }
        report { "ok": true };
    }
}
