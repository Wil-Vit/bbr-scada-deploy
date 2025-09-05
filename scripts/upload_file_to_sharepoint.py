from msal import ConfidentialClientApplication
import os
import requests
import argparse

# Azure AD app details
CLIENT_ID = os.getenv("SHAREPOINT_CLIENT_ID")
CLIENT_SECRET = os.getenv("SHAREPOINT_CLIENT_SECRET")
TENANT_ID = os.getenv("SHAREPOINT_TENANT_ID")
HOSTNAME = "bbrenergie03.sharepoint.com"
SITE_NAME = "PRODUCTION"

# SharePoint settings
SITE_NAME = "PRODUCTION"
DRIVE_NAME = "Documents"

def get_access_token():
  # Auth endpoint
  AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}"
  SCOPES = ["https://graph.microsoft.com/.default"]

  # Initialize MSAL app
  app = ConfidentialClientApplication(
      CLIENT_ID,
      authority=AUTHORITY,
      client_credential=CLIENT_SECRET
  )

  # Get token
  result = app.acquire_token_for_client(scopes=SCOPES)
  access_token = result['access_token']
  return access_token

def upload_file_to_sharepoint(FILE_PATH, FOLDER_PATH):
  access_token = get_access_token()
  headers = {"Authorization": f"Bearer {access_token}"}

  # 🔎 Get Site ID
  site_url = f"https://graph.microsoft.com/v1.0/sites/{HOSTNAME}:/sites/{SITE_NAME}"
  site_resp = requests.get(site_url, headers=headers)
  site_resp.raise_for_status()
  site_id = site_resp.json()['id']

  # 🔎 Get Drive ID (document library)
  drive_url = f"https://graph.microsoft.com/v1.0/sites/{site_id}/drives"
  drive_resp = requests.get(drive_url, headers=headers)
  drive_resp.raise_for_status()
  drive_id = drive_resp.json()['value'][0]['id']   # usually "Documents"

  # 🚀 Create Upload Session
  file_name = os.path.basename(FILE_PATH)
  upload_session_url = f"https://graph.microsoft.com/v1.0/sites/{site_id}/drives/{drive_id}/root:/{FOLDER_PATH}/{file_name}:/createUploadSession"

  upload_session_resp = requests.post(upload_session_url, headers=headers)
  upload_session_resp.raise_for_status()
  upload_url = upload_session_resp.json()['uploadUrl']   # Pre-authenticated URL

  # 📤 Upload in chunks
  chunk_size = 3276800  # 3.2 MB per chunk
  file_size = os.path.getsize(FILE_PATH)

  with open(FILE_PATH, "rb") as f:
      i = 0
      while True:
          chunk = f.read(chunk_size)
          if not chunk:
              break

          start_index = i * chunk_size
          end_index = start_index + len(chunk) - 1

          headers_chunk = {
              "Content-Length": str(len(chunk)),
              "Content-Range": f"bytes {start_index}-{end_index}/{file_size}"
          }

          print(f"Uploading bytes {start_index}-{end_index} of {file_size}...")

          put_resp = requests.put(upload_url, headers=headers_chunk, data=chunk)
          if put_resp.status_code not in (200, 201, 202):
              raise Exception("Upload failed", put_resp.text)

          i += 1

  print("✅ File uploaded successfully!")

def main():
  parser = argparse.ArgumentParser()
  parser.add_argument("--file", type=str, required=True, help="Path to the file to upload")
  parser.add_argument("--folder", type=str, required=True, help="Folder")
  args = parser.parse_args()
  upload_file_to_sharepoint(args.file, args.folder)

if __name__ == "__main__":
  main()