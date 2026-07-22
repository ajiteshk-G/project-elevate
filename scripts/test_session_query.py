#!/usr/bin/env python3
import os
import sys
import logging
logging.basicConfig(level=logging.DEBUG)

os.environ["GOOGLE_API_USE_MTLS_ENDPOINT"] = "never"
import vertexai
from google.genai import types as genai_types

PROJECT_ID = "project-elevate-503008"
PROJECT_NUMBER = "141267091689"
REGION = "us-central1"
ENGINE_ID = "6711139150235435008"
RUNTIME_NAME = f"projects/{PROJECT_NUMBER}/locations/{REGION}/reasoningEngines/{ENGINE_ID}"
PROMPT = "How many days of paid outpatient sick leave do eligible employees receive per calendar year?"
session_id_arg = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
print(f"Testing Engine {ENGINE_ID} with Session {session_id_arg or 'NEW_SESSION'}...")
vertexai.init(project=PROJECT_ID, location=REGION)
client = vertexai.Client(
    project=PROJECT_ID,
    location=REGION,
    http_options=genai_types.HttpOptions(api_version="v1beta1"),
)
remote_agent = client.agent_engines.get(
    name=f"projects/141267091689/locations/{REGION}/reasoningEngines/{ENGINE_ID}"
)

kwargs = {"message": PROMPT, "user_id": "user-123"}
if session_id_arg:
    kwargs["session_id"] = session_id_arg

try:
    print("Streaming query...")
    events = list(
        client.agent_engines._stream_query(
            name=RUNTIME_NAME,
            config={
                "class_method": "stream_query",
                "input": {"user_id": "user-123", "message": PROMPT},
            },
        )
    )
    print("SUCCESS! Events received:", len(events))
    for event in events:
        print("Event:", event)
except Exception as e:
    print(f"FAILED with error: {e}")
    import traceback
    traceback.print_exc()
