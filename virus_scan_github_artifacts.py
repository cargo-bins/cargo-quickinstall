#!/usr/bin/env python3
"""
Script to download GitHub Action artifacts, extract Windows executables,
and submit them to VirusTotal for scanning.
"""

import os
import sys
import time
import zipfile
import tarfile
import tempfile
import shutil
import hashlib
import json
import urllib.request
import urllib.parse
import urllib.error
from pathlib import Path
from typing import List, Dict, Optional
from dataclasses import dataclass


@dataclass
class ScanResult:
    filename: str
    sha256: str
    malicious: int
    suspicious: int
    harmless: int
    undetected: int
    total_engines: int
    scan_url: str
    is_safe: bool


class GitHubArtifactScanner:
    def __init__(self, virustotal_api_key: str, github_token: Optional[str] = None):
        self.vt_api_key = virustotal_api_key
        self.github_token = github_token

    def _make_request(
        self,
        url: str,
        headers: Optional[Dict[str, str]] = None,
        data: Optional[bytes] = None,
    ) -> Dict:
        """Make HTTP request using urllib."""
        if headers is None:
            headers = {}

        # Add GitHub token if available
        if self.github_token and "github.com" in url:
            headers["Authorization"] = f"token {self.github_token}"

        headers["User-Agent"] = "cargo-quickinstall-virus-scanner/1.0"

        req = urllib.request.Request(url, data=data, headers=headers)

        try:
            with urllib.request.urlopen(req) as response:
                if response.status != 200:
                    print(f"HTTP request failed: {response.status}: {response.reason}")
                    sys.exit(1)
                return json.loads(response.read().decode())
        except urllib.error.HTTPError as e:
            print(f"HTTP request failed: {e.code}: {e.reason}")
            sys.exit(1)
        except Exception as e:
            print(f"Request failed: {e}")
            sys.exit(1)

    def _download_file(
        self, url: str, file_path: Path, headers: Optional[Dict[str, str]] = None
    ) -> None:
        """Download file using urllib."""
        if headers is None:
            headers = {}

        if self.github_token and "github.com" in url:
            headers["Authorization"] = f"token {self.github_token}"

        headers["User-Agent"] = "cargo-quickinstall-virus-scanner/1.0"

        req = urllib.request.Request(url, headers=headers)

        try:
            with urllib.request.urlopen(req) as response:
                # GitHub artifact downloads return 302 redirects, urllib handles this automatically
                if response.status not in [200, 302]:
                    print(f"Download failed: HTTP {response.status}")
                    sys.exit(1)

                with open(file_path, "wb") as f:
                    shutil.copyfileobj(response, f)
        except urllib.error.HTTPError as e:
            print(f"Download failed: HTTP {e.code}: {e.reason}")
            sys.exit(1)
        except Exception as e:
            print(f"Download failed: {e}")
            sys.exit(1)

    def get_workflow_artifacts(self, repo: str, run_id: str) -> List[Dict]:
        """Fetch artifacts from a GitHub Actions workflow run."""
        url = f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/artifacts"

        result = self._make_request(url)
        return result.get("artifacts", [])

    def download_artifact(
        self, artifact_name: str, artifact_id: str, download_path: Path
    ) -> None:
        """Download an artifact using GitHub CLI."""
        print(f"Downloading artifact {artifact_name}...")

        # Use GitHub CLI to download the artifact
        import subprocess

        try:
            # Download to a temporary directory first
            temp_download_dir = download_path.parent / f"temp_{artifact_name}"
            temp_download_dir.mkdir(exist_ok=True)

            result = subprocess.run(
                [
                    "gh",
                    "run",
                    "download",
                    str(artifact_id),
                    "--repo",
                    "cargo-bins/cargo-quickinstall",
                    "--name",
                    artifact_name,
                    "--dir",
                    str(temp_download_dir),
                ],
                capture_output=True,
                text=True,
                cwd=download_path.parent,
            )

            if result.returncode != 0:
                print(f"GitHub CLI download failed: {result.stderr}")
                sys.exit(1)

            # Find the downloaded files and move them to our expected location
            downloaded_files = list(temp_download_dir.rglob("*"))
            downloaded_files = [f for f in downloaded_files if f.is_file()]

            if not downloaded_files:
                print(f"No files found in downloaded artifact {artifact_name}")
                return

            # For simplicity, create a zip file with all downloaded content
            import zipfile

            with zipfile.ZipFile(download_path, "w") as zipf:
                for file_path in downloaded_files:
                    arcname = file_path.relative_to(temp_download_dir)
                    zipf.write(file_path, arcname)

            # Clean up temp directory
            shutil.rmtree(temp_download_dir)
            print(f"Downloaded {len(downloaded_files)} files to {download_path}")

        except FileNotFoundError:
            print("Error: GitHub CLI (gh) not found. Please install it first.")
            sys.exit(1)
        except Exception as e:
            print(f"Error downloading artifact: {e}")
            sys.exit(1)

    def extract_windows_executables(
        self, artifact_path: Path, extract_dir: Path
    ) -> List[Path]:
        """Extract Windows executables from artifact zip and nested archives."""
        executables = []
        seen_hashes = set()  # Track SHA256 hashes to avoid duplicates

        print(f"Extracting artifact: {artifact_path}")

        # First extract the artifact zip
        with zipfile.ZipFile(artifact_path, "r") as zip_ref:
            zip_ref.extractall(extract_dir)

        # Look for nested archives and executables
        for item in extract_dir.rglob("*"):
            if item.is_file():
                if item.suffix.lower() == ".exe":
                    # Check if we've already seen this executable
                    sha256 = self.calculate_sha256(item)
                    if sha256 not in seen_hashes:
                        print(f"Found executable: {item}")
                        executables.append(item)
                        seen_hashes.add(sha256)
                    else:
                        print(f"Skipping duplicate executable: {item}")
                elif item.suffix.lower() in [".zip", ".gz", ".tar"]:
                    # Extract nested archives
                    nested_executables = self._extract_nested_archive(
                        item, item.parent / f"{item.stem}_extracted"
                    )
                    # Filter out duplicates from nested archives
                    for exe in nested_executables:
                        sha256 = self.calculate_sha256(exe)
                        if sha256 not in seen_hashes:
                            executables.append(exe)
                            seen_hashes.add(sha256)
                        else:
                            print(
                                f"Skipping duplicate executable from nested archive: {exe}"
                            )
                elif item.name.endswith(".tar.gz"):
                    # Handle .tar.gz files
                    nested_executables = self._extract_nested_archive(
                        item, item.parent / f"{item.stem}_extracted"
                    )
                    # Filter out duplicates from nested archives
                    for exe in nested_executables:
                        sha256 = self.calculate_sha256(exe)
                        if sha256 not in seen_hashes:
                            executables.append(exe)
                            seen_hashes.add(sha256)
                        else:
                            print(
                                f"Skipping duplicate executable from nested archive: {exe}"
                            )

        return executables

    def _extract_nested_archive(
        self, archive_path: Path, extract_dir: Path
    ) -> List[Path]:
        """Extract nested archive and find executables."""
        executables = []
        extract_dir.mkdir(exist_ok=True)

        try:
            if archive_path.suffix.lower() == ".zip":
                with zipfile.ZipFile(archive_path, "r") as zip_ref:
                    zip_ref.extractall(extract_dir)
            elif archive_path.name.endswith(
                ".tar.gz"
            ) or archive_path.suffix.lower() in [".tar", ".gz"]:
                with tarfile.open(archive_path, "r:*") as tar_ref:
                    tar_ref.extractall(extract_dir)

            # Find executables in extracted content
            for item in extract_dir.rglob("*.exe"):
                if item.is_file():
                    print(f"Found executable in nested archive: {item}")
                    executables.append(item)

        except Exception as e:
            print(f"Failed to extract {archive_path}: {e}")

        return executables

    def calculate_sha256(self, file_path: Path) -> str:
        """Calculate SHA256 hash of a file."""
        sha256_hash = hashlib.sha256()
        with open(file_path, "rb") as f:
            for chunk in iter(lambda: f.read(4096), b""):
                sha256_hash.update(chunk)
        return sha256_hash.hexdigest()

    def submit_file_to_virustotal(self, file_path: Path) -> str:
        """Submit a file to VirusTotal and return scan ID."""
        print(f"Submitting {file_path.name} to VirusTotal")

        url = "https://www.virustotal.com/api/v3/files"

        # Create multipart form data manually
        boundary = "----formdata-" + str(int(time.time()))

        # Read file content
        with open(file_path, "rb") as f:
            file_content = f.read()

        # Build multipart form data
        form_data = []
        form_data.append(f"--{boundary}".encode())
        form_data.append(
            f'Content-Disposition: form-data; name="file"; filename="{file_path.name}"'.encode()
        )
        form_data.append(b"Content-Type: application/octet-stream")
        form_data.append(b"")
        form_data.append(file_content)
        form_data.append(f"--{boundary}--".encode())

        body = b"\r\n".join(form_data)

        headers = {
            "X-Apikey": self.vt_api_key,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
        }

        req = urllib.request.Request(url, data=body, headers=headers)

        try:
            with urllib.request.urlopen(req) as response:
                if response.status != 200:
                    error_text = response.read().decode()
                    print(
                        f"VirusTotal submission failed: {response.status} - {error_text}"
                    )
                    sys.exit(1)

                result = json.loads(response.read().decode())
                return result["data"]["id"]
        except urllib.error.HTTPError as e:
            if e.code == 409:  # Conflict error - file already being processed
                error_text = e.read().decode() if hasattr(e, "read") else str(e)
                print(
                    f"File already being processed by VirusTotal, trying to get existing results..."
                )
                # Try to get results using file hash instead
                sha256 = self.calculate_sha256(file_path)
                return f"file-{sha256}"  # Return a special scan ID to indicate we should check file hash
            else:
                error_text = e.read().decode() if hasattr(e, "read") else str(e)
                print(f"VirusTotal submission failed: {e.code} - {error_text}")
                sys.exit(1)
        except Exception as e:
            print(f"VirusTotal submission failed: {e}")
            sys.exit(1)

    def get_scan_results(self, scan_id: str) -> Dict:
        """Get scan results from VirusTotal."""
        if scan_id.startswith("file-"):
            # This is a file hash, not an analysis ID
            file_hash = scan_id[5:]  # Remove "file-" prefix
            url = f"https://www.virustotal.com/api/v3/files/{file_hash}"
        else:
            # This is a normal analysis ID
            url = f"https://www.virustotal.com/api/v3/analyses/{scan_id}"

        headers = {"X-Apikey": self.vt_api_key}

        max_retries = 30  # 15 minutes max wait
        retry_count = 0

        while retry_count < max_retries:
            try:
                req = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(req) as response:
                    if response.status != 200:
                        print(f"Failed to get scan results: {response.status}")
                        sys.exit(1)

                    result = json.loads(response.read().decode())

                    if scan_id.startswith("file-"):
                        # For file hash requests, we get results directly
                        return {"data": {"attributes": result["data"]["attributes"]}}
                    else:
                        # For analysis requests, check status
                        status = result["data"]["attributes"]["status"]

                        if status == "completed":
                            return result
                        elif status in ["queued", "running"]:
                            print(
                                f"Scan in progress... (attempt {retry_count + 1}/{max_retries})"
                            )
                            time.sleep(30)  # Wait 30 seconds
                            retry_count += 1
                        else:
                            print(f"Unexpected scan status: {status}")
                            sys.exit(1)
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    if scan_id.startswith("file-"):
                        print("File not found in VirusTotal database")
                        sys.exit(1)
                    else:
                        print("Scan ID not found")
                        sys.exit(1)
                print(f"Failed to get scan results: {e.code} - {e.reason}")
                sys.exit(1)
            except Exception as e:
                print(f"Failed to get scan results: {e}")
                sys.exit(1)

        print("Timeout waiting for scan results")
        sys.exit(1)

    def parse_scan_result(
        self, vt_result: Dict, filename: str, sha256: str
    ) -> ScanResult:
        """Parse VirusTotal scan result."""
        # Handle both analysis results and file hash results
        if "stats" in vt_result["data"]["attributes"]:
            stats = vt_result["data"]["attributes"]["stats"]
        elif "last_analysis_stats" in vt_result["data"]["attributes"]:
            stats = vt_result["data"]["attributes"]["last_analysis_stats"]
        else:
            print(f"Warning: Could not find stats in VirusTotal result for {filename}")
            stats = {"malicious": 0, "suspicious": 0, "harmless": 0, "undetected": 0}

        malicious = stats.get("malicious", 0)
        suspicious = stats.get("suspicious", 0)
        harmless = stats.get("harmless", 0)
        undetected = stats.get("undetected", 0)
        total = malicious + suspicious + harmless + undetected

        scan_url = f"https://www.virustotal.com/gui/file/{sha256}"
        is_safe = malicious == 0 and suspicious <= 2  # Allow up to 2 false positives

        return ScanResult(
            filename=filename,
            sha256=sha256,
            malicious=malicious,
            suspicious=suspicious,
            harmless=harmless,
            undetected=undetected,
            total_engines=total,
            scan_url=scan_url,
            is_safe=is_safe,
        )

    def scan_executable(self, exe_path: Path) -> ScanResult:
        """Scan a single executable file."""
        filename = exe_path.name
        sha256 = self.calculate_sha256(exe_path)

        print(f"\nScanning: {filename}")
        print(f"SHA256: {sha256}")
        print(f"Size: {exe_path.stat().st_size} bytes")

        try:
            # Submit file
            scan_id = self.submit_file_to_virustotal(exe_path)
            print(f"Scan ID: {scan_id}")

            # Wait for and get results
            vt_result = self.get_scan_results(scan_id)

            # Parse results
            result = self.parse_scan_result(vt_result, filename, sha256)

            return result
        except Exception as e:
            print(f"Failed to scan {filename}: {e}")
            sys.exit(1)


def load_env_file():
    """Load environment variables from .env file."""
    env_file = Path(".env")
    if env_file.exists():
        with open(env_file, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    os.environ[key.strip()] = value.strip()


def main():
    # Load environment variables
    load_env_file()

    # Configuration
    repo = "cargo-bins/cargo-quickinstall"
    run_id = "17261615966"  # Example run ID

    # Get API keys
    vt_api_key = os.getenv("VIRUSTOTAL_API_KEY")
    github_token = os.getenv("GITHUB_TOKEN")  # Optional, for higher rate limits

    if not vt_api_key:
        print("Error: VIRUSTOTAL_API_KEY environment variable is required")
        print("Please set it in your .env file or environment")
        sys.exit(1)

    print(f"Starting virus scan of artifacts from {repo} run {run_id}")

    results = []
    scanner = GitHubArtifactScanner(vt_api_key, github_token)

    # Create temporary directory
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)

        # Get artifacts
        print("Fetching artifacts...")
        try:
            artifacts = scanner.get_workflow_artifacts(repo, run_id)
            print(f"Found {len(artifacts)} artifacts")
        except Exception as e:
            print(f"Error fetching artifacts: {e}")
            sys.exit(1)

        for artifact in artifacts:
            artifact_name = artifact["name"]
            artifact_id = artifact["workflow_run"][
                "id"
            ]  # Use the run ID for downloading

            # Skip non-Windows artifacts
            if (
                "windows" not in artifact_name.lower()
                and "win" not in artifact_name.lower()
            ):
                print(f"Skipping non-Windows artifact: {artifact_name}")
                continue

            print(f"\nProcessing artifact: {artifact_name}")

            try:
                # Download artifact
                artifact_path = temp_path / f"{artifact_name}.zip"
                scanner.download_artifact(artifact_name, artifact_id, artifact_path)

                # Extract executables
                extract_dir = temp_path / artifact_name
                executables = scanner.extract_windows_executables(
                    artifact_path, extract_dir
                )

                if not executables:
                    print(f"No Windows executables found in {artifact_name}")
                    continue

                # Scan each executable
                for exe_path in executables:
                    result = scanner.scan_executable(exe_path)
                    results.append(result)

                    # Print immediate results
                    status = "✅ CLEAN" if result.is_safe else "🚨 FLAGGED"
                    print(f"{status}: {result.filename}")
                    print(
                        f"  Malicious: {result.malicious}, Suspicious: {result.suspicious}"
                    )
                    print(f"  Report: {result.scan_url}")

                    # Rate limiting (VirusTotal free tier: 4 requests/minute)
                    print("Waiting 15 seconds for rate limiting...")
                    time.sleep(15)

            except Exception as e:
                print(f"Error processing artifact {artifact_name}: {e}")
                sys.exit(1)

    # Generate final report
    print("\n" + "=" * 60)
    print("FINAL VIRUS SCAN REPORT")
    print("=" * 60)

    total_scanned = len(results)
    flagged_count = sum(1 for r in results if not r.is_safe)
    clean_count = total_scanned - flagged_count

    print(f"Total files scanned: {total_scanned}")
    print(f"Clean files: {clean_count}")
    print(f"Flagged files: {flagged_count}")

    if flagged_count > 0:
        print("\nFLAGGED FILES:")
        for result in results:
            if not result.is_safe:
                print(f"🚨 {result.filename}")
                print(f"   SHA256: {result.sha256}")
                print(
                    f"   Malicious: {result.malicious}, Suspicious: {result.suspicious}"
                )
                print(f"   Report: {result.scan_url}")
                print()

    # Save detailed report
    report_path = Path("virus_scan_report.json")
    report_data = {
        "scan_timestamp": time.time(),
        "repo": repo,
        "run_id": run_id,
        "summary": {
            "total_scanned": total_scanned,
            "clean": clean_count,
            "flagged": flagged_count,
        },
        "results": [
            {
                "filename": r.filename,
                "sha256": r.sha256,
                "malicious": r.malicious,
                "suspicious": r.suspicious,
                "harmless": r.harmless,
                "undetected": r.undetected,
                "total_engines": r.total_engines,
                "is_safe": r.is_safe,
                "scan_url": r.scan_url,
            }
            for r in results
        ],
    }

    try:
        with open(report_path, "w") as f:
            json.dump(report_data, f, indent=2)
        print(f"\nDetailed report saved to: {report_path}")
    except Exception as e:
        print(f"Error saving report: {e}")
        sys.exit(1)

    # Exit with error code if any files were flagged
    if flagged_count > 0:
        print(f"\n⚠️  {flagged_count} files were flagged as potentially malicious!")
        sys.exit(1)

    print("\n✅ All scanned files are clean!")
    sys.exit(0)


if __name__ == "__main__":
    main()
