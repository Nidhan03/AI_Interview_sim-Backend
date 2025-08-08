import streamlit as st;
import requests;
import base64;
import sys;


def render_interview_form(){
    (col1, col2) = st.columns(2);
    with col1{
        interview_type = st.selectbox(
            "Interview Type",
            [
                "Behavioral",
                "Situational",
                "Technical",
                "Case Study",
                "HR/Personality",
                "Problem-Solving",
                "Academic"
            ]
        );
    }
    with col2{
        duration = st.text_input(
            "Interview Duration (minutes)",
            placeholder="Max time: 30 mins",
            help="Enter a number in minutes (e.g., 15, 30)"
        );
        if duration{
            try{
                duration_int = int(duration);
                if duration_int <= 0 or duration_int > 30{
                    st.error("Please enter a duration between 1 and 30 minutes.");
                }
            }
            except ValueError{
                st.error("Please enter a valid number for duration.");
            }
    }
    }
    job_description = st.text_area("Job Description", height=150);
    resume_file = st.file_uploader("Upload Resume or Additional Info (Optional)", ["pdf", "docx", "txt"]);
    
    
    if st.button("Submit"){
        
        if not interview_type or not duration or not job_description.strip(){
            st.error("⚠️ Please complete all the essential fields.");
        }else{
            st.write("**Interview Type:**", interview_type);
            st.write("**Duration:**", f"{duration} minutes");
            st.write("**Job Description:**", job_description);
            if resume_file{
                st.write("**File Uploaded:**", resume_file.name);
            }else{
                st.write("**No file uploaded.**");
            }

            return {
                "interview_type": interview_type,
                "duration": duration,
                "job_description": job_description,
                "resume_file": resume_file
            };
        }
    }
}

with entry{

    st.title("Welcome to the AI Interview Simulator!");
    st.set_page_config(
        page_title="AI Interview Simulator",
        layout="wide"
    );

    interview_data = render_interview_form();

    if interview_data{
        file_uploaded = False if (interview_data["resume_file"] == None) else True;

        if interview_data["resume_file"] != None{
            resume_file_name = interview_data["resume_file"].name;
            resume_file_data = base64.b64encode(interview_data["resume_file"].getvalue()).decode('utf-8');
        }else{
            resume_file_name = "";
            resume_file_data = "";
        }
        payload = {
            "interview_type": interview_data["interview_type"],
            "job_description": interview_data["job_description"],
            "duration": interview_data["duration"],
            "file_uploaded": file_uploaded,
            "file_name": resume_file_name,
            "file_data": resume_file_data,
        };
        response = requests.post("http://localhost:8000/walker/create_interview_session", json=payload);

        if response.status_code == 200{
            st.spinner("Creating interview session...");
            session_id = response.json()["reports"][0]["session_id"];
            st.success(f"Interview session created successfully! Session ID: {session_id}");
        }else{
            st.error("Failed to create interview session. Please try again.");
        }
    }
    
}

