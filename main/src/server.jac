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
    
}

walker interact{
    has session_id: str;

    can get_response with `root entry{
        visit [-->](`?Session)(?session_id == self.session_id);
    }

}

walker create_interview{
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
        report {"session_id": session_id};
    }
}
