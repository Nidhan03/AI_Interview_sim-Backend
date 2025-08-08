import uuid;
import os;
import base64;
import requests;


node Session {
    has session_id: str;
    has interview_type: str;
    has job_description:str;
    has duration: str;
    has file_uploaded: bool;
    has file_path: str;
    has chat_history: list[dict] = [];
    has agent_id: str = "";


    can create_interview_agent with create_interview_session entry{

        url = "https://api.elevenlabs.io/v1/convai/agents/create";
        headers={
        "xi-api-key": os.getenv("ELEVENLABS_API_KEY")
        };
        data = {
            "conversation_config": {
            "asr": {
                "quality": "high",
                "provider": "elevenlabs",
                "user_input_audio_format": "pcm_16000"
            },
            "turn": {
                "turn_timeout": 10,
                "silence_end_call_timeout": -1,
                "mode": "silence"
            },
            "conversation": {
                "max_duration_seconds": int(self.duration) * 60,  #duration must be in seconds
            },
            "agent": {
                "first_message": "hello",
                "prompt": {
                "prompt": "You are an AI interview agent. Your task is to conduct a mock interview for a HR position.",
                }
            }
            },
            "name": "interview_agent",
        };

        
        agent_id = requests.post(url, headers=headers, json=data);
        report {"session_id": self.session_id};
    }

    can start_interview with start_interview_session entry{


    }
}


walker start_interview_session{

}


walker create_interview_session{
    has interview_type: str;
    has job_description:str;
    has duration: str;
    has file_uploaded: bool;
    has file_name: str;
    has file_data: str;

    obj __specs__ {
        static has auth: bool = False;
    }
    
    def save_file(session_id: str, file_name: str, file_data: str){
        UPLOAD_DIR = os.path.join("uploads", session_id);
        if not os.path.exists(UPLOAD_DIR) {
            os.makedirs(UPLOAD_DIR);
        }

        file_path = os.path.join(UPLOAD_DIR, file_name);
        data = base64.b64decode(file_data.encode('utf-8'));

        with open(file_path, 'wb') as f { # Writing binary to specific path/file_object
            f.write(data);
        }

        return {
            "status": "uploaded",
            "file_path": file_path
        };
    }
    
    can save_interview_data with `root entry{
        session_id = str(uuid.uuid4());
        print(f"session: {session_id} created");

        file_path = "";
        if self.file_uploaded{
            file_path = self.save_file(session_id, self.file_name, self.file_data)["file_path"];
        }

        new_session = Session(session_id, self.interview_type, self.job_description, self.duration, self.file_uploaded, file_path);
        root ++> new_session;
        visit new_session;
    }
}
