#!/usr/bin/env python3
import os
from google.cloud import discoveryengine_v1 as discoveryengine

def main():
    project_id = "nishantmk-forge-ai-security"
    
    for location in ["global", "us"]:
        client = discoveryengine.EngineServiceClient(transport="rest")
        parent = f"projects/{project_id}/locations/{location}/collections/default_collection"
        
        print(f"Listing engines in {parent}...")
        try:
            request = discoveryengine.ListEnginesRequest(parent=parent)
            page_result = client.list_engines(request=request)
            for response in page_result:
                print(f"Engine ID: {response.name}")
                print(f"  Display Name: {response.display_name}")
        except Exception as e:
            print(f"Error listing engines in {location}: {e}")

if __name__ == "__main__":
    main()
