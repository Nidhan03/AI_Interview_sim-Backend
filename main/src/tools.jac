import from mtllm.llm {Model}

glob llm = Model(model_name="gemini/gemini-2.0-flash");


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
Generate a structured prompt for an interview agent based on the defined format to conduct a realistic interview simulation.  

Returns:
    str: A fully formatted prompt ready for the interview agent.
"""
def generate_interview_agent_prompt(interview_type: str, job_description: str, interviewee_cv_data: str ) -> str by llm(tools=[read_prompt_format, get_interview_questions, get_interviewee_summary]);


