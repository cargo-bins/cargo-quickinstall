#!/usr/bin/env python3
"""
Script to download GitHub Action artifacts, extract Windows executables,
and submit them to VirusTotal for scanning.

Usage:
  python3 virus_scan_github_artifacts.py [start_from_run_id]
  python3 virus_scan_github_artifacts.py --continuous
  python3 virus_scan_github_artifacts.py --interval=600

Optional arguments:
  start_from_run_id    Start scanning from this run ID onwards (skipping older runs), but skip this run ID itself
  --continuous         Run continuously, checking for new builds every 1 minute
  --interval=N         Set check interval for continuous mode (seconds, default: 60)

Examples:
  python3 virus_scan_github_artifacts.py 17256193567
  python3 virus_scan_github_artifacts.py --continuous
  python3 virus_scan_github_artifacts.py --interval=600

Continuous mode will:
- Check for new Windows builds every N seconds (default: 60 = 1 minute)
- Only scan builds that haven't been scanned before
- Update the virus_scan_report.json file after each new scan
- Include build information (ID, name, date) for each scanned binary
- Run forever until interrupted with Ctrl+C
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
    build_id: str
    build_name: str
    build_date: str


class GitHubArtifactScanner:
    def __init__(self, virustotal_api_key: str, github_token: Optional[str] = None):
        self.vt_api_key = virustotal_api_key
        self.github_token = github_token
        self.report_path = Path("virus_scan_report.json")
        self.scanned_builds = set()
        self.all_results = []
        self.last_page_position = 1  # Track last page position
        self.last_run_id = None  # Track the most recent run ID we've seen
        self.load_existing_report()

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

    def get_windows_builds(
        self,
        repo: str,
        max_builds: int = 10,
        max_pages: int = 5,
        start_from_run_id: Optional[str] = None,
        start_page: int = 1,
    ) -> List[Dict[str, str]]:
        """Find recent Windows builds using GitHub API."""
        print(f"Searching for Windows builds in {repo}...")
        if start_from_run_id:
            print(
                f"Will start scanning from run ID {start_from_run_id} onwards (skipping older runs) but will skip that run ID itself"
            )

        print(f"Starting search from page {start_page}")

        windows_runs = []
        found_start_run = (
            start_from_run_id is None
        )  # If no start_from_run_id, start immediately

        for page in range(start_page, start_page + max_pages):
            print(f"Checking page {page}...")
            url = f"https://api.github.com/repos/{repo}/actions/runs?per_page=100&page={page}"

            try:
                result = self._make_request(url)
                workflow_runs = result.get("workflow_runs", [])

                if not workflow_runs:
                    print(f"No more workflow runs found on page {page}")
                    break

                # Track the most recent run ID we encounter (from the first page)
                if page == start_page and workflow_runs and self.last_run_id is None:
                    self.last_run_id = str(workflow_runs[0]["id"])

                # Filter for successful Windows builds
                for run in workflow_runs:
                    if (
                        run.get("conclusion") == "success"
                        and "windows" in run.get("name", "").lower()
                    ):
                        run_id = str(run["id"])

                        # If we haven't found our starting point yet, keep looking
                        if not found_start_run:
                            if run_id == start_from_run_id:
                                found_start_run = True
                                print(
                                    f"Found starting run ID {start_from_run_id}, will begin scanning from here (but skip this run)"
                                )
                                continue  # Skip this run ID itself
                            else:
                                print(f"Skipping run {run_id} (before start point)")
                                continue

                        # Also skip the start_from_run_id if we encounter it again
                        if start_from_run_id and run_id == start_from_run_id:
                            print(f"Skipping run {run_id} (excluded start point)")
                            continue

                        build_info = {
                            "id": run_id,
                            "name": run["name"],
                            "date": run["created_at"],
                        }
                        windows_runs.append(build_info)
                        print(
                            f"Found Windows build: {run['id']} - {run['name']} ({run['created_at']})"
                        )

                        if len(windows_runs) >= max_builds:
                            # Store the current page position
                            self.last_page_position = page
                            break

                if len(windows_runs) >= max_builds:
                    break

            except Exception as e:
                print(f"Error fetching workflow runs from page {page}: {e}")
                break

        if start_from_run_id and not found_start_run:
            print(
                f"Warning: Starting run ID {start_from_run_id} not found in the searched pages"
            )

        print(f"Found {len(windows_runs)} Windows builds to scan")
        return windows_runs

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
        self,
        vt_result: Dict,
        filename: str,
        sha256: str,
        build_id: str = "",
        build_name: str = "",
        build_date: str = "",
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
            build_id=build_id,
            build_name=build_name,
            build_date=build_date,
        )

    def scan_multiple_runs(
        self, repo: str, builds: List[Dict[str, str]]
    ) -> List[ScanResult]:
        """Scan executables from multiple workflow runs."""
        all_results = []

        # Create temporary directory
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)

            for i, build in enumerate(builds, 1):
                run_id = build["id"]
                build_name = build["name"]
                build_date = build["date"]

                print(f"\n{'='*60}")
                print(f"PROCESSING RUN {i}/{len(builds)}: {run_id}")
                print(f"BUILD: {build_name} ({build_date})")
                print(f"{'='*60}")

                try:
                    # Get artifacts for this run
                    artifacts = self.get_workflow_artifacts(repo, run_id)
                    print(f"Found {len(artifacts)} artifacts")

                    if not artifacts:
                        print(f"No artifacts found for run {run_id}")
                        continue

                    run_results = self.scan_run_artifacts(
                        repo, run_id, artifacts, temp_path, build_name, build_date
                    )
                    all_results.extend(run_results)

                except Exception as e:
                    print(f"Error processing run {run_id}: {e}")
                    # Continue with other runs instead of exiting
                    continue

        return all_results

    def scan_executable(
        self,
        exe_path: Path,
        build_id: str = "",
        build_name: str = "",
        build_date: str = "",
    ) -> ScanResult:
        """Scan a single executable file."""
        filename = exe_path.name
        sha256 = self.calculate_sha256(exe_path)
        file_size = exe_path.stat().st_size

        print(f"\nScanning: {filename}")
        print(f"SHA256: {sha256}")
        print(f"Size: {file_size} bytes ({file_size / (1024*1024):.1f} MB)")

        # Skip files larger than 32MB (VirusTotal's limit is ~650MB but free tier is much lower)
        if file_size > 32 * 1024 * 1024:
            print(
                f"⚠️  Skipping {filename} - file too large ({file_size / (1024*1024):.1f} MB)"
            )
            # Return a "safe" result for large files to avoid blocking the scan
            return ScanResult(
                filename=filename,
                sha256=sha256,
                malicious=0,
                suspicious=0,
                harmless=0,
                undetected=0,
                total_engines=0,
                scan_url=f"https://www.virustotal.com/gui/file/{sha256}",
                is_safe=True,  # Assume safe to not block CI
                build_id=build_id,
                build_name=build_name,
                build_date=build_date,
            )

        try:
            # Submit file
            scan_id = self.submit_file_to_virustotal(exe_path)
            print(f"Scan ID: {scan_id}")

            # Wait for and get results
            vt_result = self.get_scan_results(scan_id)

            # Parse results
            result = self.parse_scan_result(
                vt_result, filename, sha256, build_id, build_name, build_date
            )

            return result
        except Exception as e:
            print(f"Failed to scan {filename}: {e}")
            sys.exit(1)

    def scan_run_artifacts(
        self,
        repo: str,
        run_id: str,
        artifacts: List[Dict],
        temp_path: Path,
        build_name: str = "",
        build_date: str = "",
    ) -> List[ScanResult]:
        """Scan artifacts from a single run."""
        results = []

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
                artifact_path = temp_path / f"{run_id}_{artifact_name}.zip"
                self.download_artifact(artifact_name, artifact_id, artifact_path)

                # Extract executables
                extract_dir = temp_path / f"{run_id}_{artifact_name}"
                executables = self.extract_windows_executables(
                    artifact_path, extract_dir
                )

                if not executables:
                    print(f"No Windows executables found in {artifact_name}")
                    continue

                # Scan each executable
                for exe_path in executables:
                    result = self.scan_executable(
                        exe_path, run_id, build_name, build_date
                    )
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
                # Continue with other artifacts instead of exiting
                continue

        return results

    def load_existing_report(self) -> None:
        """Load existing scan report to avoid rescanning builds."""
        if self.report_path.exists():
            try:
                with open(self.report_path, "r") as f:
                    data = json.load(f)
                    # Ensure all build IDs are strings for consistent comparison
                    scanned_build_ids = data.get("windows_builds_scanned", [])
                    self.scanned_builds = set(
                        str(build_id) for build_id in scanned_build_ids
                    )

                    # Load page position tracking
                    self.last_page_position = data.get("last_page_position", 1)
                    self.last_run_id = data.get("last_run_id")

                    # Load existing results
                    for result_data in data.get("results", []):
                        result = ScanResult(
                            filename=result_data["filename"],
                            sha256=result_data["sha256"],
                            malicious=result_data["malicious"],
                            suspicious=result_data["suspicious"],
                            harmless=result_data["harmless"],
                            undetected=result_data["undetected"],
                            total_engines=result_data["total_engines"],
                            scan_url=result_data["scan_url"],
                            is_safe=result_data["is_safe"],
                            build_id=result_data.get("build_id", ""),
                            build_name=result_data.get("build_name", ""),
                            build_date=result_data.get("build_date", ""),
                        )
                        self.all_results.append(result)
                    print(
                        f"Loaded existing report with {len(self.scanned_builds)} scanned builds and {len(self.all_results)} results"
                    )
                    print(f"Will continue from page {self.last_page_position}")
            except Exception as e:
                print(f"Error loading existing report: {e}")
                self.scanned_builds = set()
                self.all_results = []
                self.last_page_position = 1
                self.last_run_id = None
        else:
            print("No existing report found, starting fresh")

    def save_report(self, repo: str) -> None:
        """Save current scan report to file."""
        total_scanned = len(self.all_results)
        flagged_count = sum(1 for r in self.all_results if not r.is_safe)
        clean_count = total_scanned - flagged_count

        report_data = {
            "scan_timestamp": time.time(),
            "repo": repo,
            "windows_builds_scanned": list(self.scanned_builds),
            "last_page_position": self.last_page_position,
            "last_run_id": self.last_run_id,
            "summary": {
                "builds_scanned": len(self.scanned_builds),
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
                    "build_id": r.build_id,
                    "build_name": r.build_name,
                    "build_date": r.build_date,
                }
                for r in self.all_results
            ],
        }

        try:
            with open(self.report_path, "w") as f:
                json.dump(report_data, f, indent=2)
            print(f"Report updated: {self.report_path}")
        except Exception as e:
            print(f"Error saving report: {e}")

    def continuous_scan(self, repo: str, check_interval: int = 60) -> None:
        """Run continuous scanning, checking for new builds every check_interval seconds."""
        print(f"Starting continuous virus scanning for {repo}")
        print(f"Checking for new builds every {check_interval} seconds")
        print(f"Report will be updated after each scan: {self.report_path}")
        print(f"Already scanned builds: {len(self.scanned_builds)}")
        if self.scanned_builds:
            print(f"  Most recent: {sorted(self.scanned_builds, reverse=True)[:5]}")

        while True:
            try:
                print(f"\n{'='*80}")
                print(f"CONTINUOUS SCAN CHECK - {time.strftime('%Y-%m-%d %H:%M:%S')}")
                print(f"{'='*80}")

                # Check if we have new builds by looking at page 1 first
                recent_builds = self.get_windows_builds(
                    repo, max_builds=5, max_pages=1, start_page=1
                )

                # If we find any new builds on page 1, reset to page 1
                has_new_builds_on_page_1 = any(
                    str(build["id"]) not in self.scanned_builds
                    for build in recent_builds
                )

                if has_new_builds_on_page_1:
                    print(
                        "Found new builds on page 1, resetting search to start from page 1"
                    )
                    start_page = 1
                    self.last_page_position = 1
                else:
                    print(
                        f"No new builds on page 1, continuing from page {self.last_page_position}"
                    )
                    start_page = self.last_page_position

                # Find new builds starting from the appropriate page
                all_builds = self.get_windows_builds(
                    repo, max_builds=20, max_pages=10, start_page=start_page
                )
                print(f"Found {len(all_builds)} total Windows builds")

                # Filter out already scanned builds
                new_builds = []
                for build in all_builds:
                    build_id = str(build["id"])  # Ensure it's a string for comparison
                    if build_id not in self.scanned_builds:
                        new_builds.append(build)
                        print(f"  NEW: {build_id} - {build['name'][:50]}...")
                    else:
                        print(f"  SKIP: {build_id} - already scanned")

                if not new_builds:
                    print("No new Windows builds found to scan.")
                    # Advance page position if we didn't find anything new
                    self.last_page_position += 1
                    print(f"Advanced to page {self.last_page_position} for next check")
                    # Save the updated page position
                    self.save_report(repo)
                else:
                    print(f"\nWill scan {len(new_builds)} new Windows builds")

                    # Scan new builds
                    new_results = self.scan_multiple_runs(repo, new_builds)

                    # Add results and update scanned builds
                    self.all_results.extend(new_results)
                    for build in new_builds:
                        build_id = str(build["id"])  # Ensure it's a string
                        self.scanned_builds.add(build_id)
                        print(f"Added build {build_id} to scanned list")

                    # Save updated report
                    self.save_report(repo)
                    print(f"Total scanned builds now: {len(self.scanned_builds)}")

                    # Print summary of new results
                    if new_results:
                        flagged = [r for r in new_results if not r.is_safe]
                        if flagged:
                            print(f"\n🚨 {len(flagged)} NEW FLAGGED FILES:")
                            for result in flagged:
                                print(f"  {result.filename} (Build: {result.build_id})")
                                print(f"    Report: {result.scan_url}")
                        else:
                            print(f"\n✅ All {len(new_results)} new files are clean!")

                print(f"\nWaiting {check_interval} seconds before next check...")
                time.sleep(check_interval)

            except KeyboardInterrupt:
                print("\nStopping continuous scan...")
                break
            except Exception as e:
                print(f"Error in continuous scan: {e}")
                print(f"Waiting {check_interval} seconds before retrying...")
                time.sleep(check_interval)


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

    # Parse command line arguments
    start_from_run_id = None
    continuous_mode = False
    check_interval = 60  # 1 minute default for continuous mode

    if len(sys.argv) > 1:
        if sys.argv[1] in ["-h", "--help", "help"]:
            print(__doc__)
            sys.exit(0)
        elif sys.argv[1] == "--continuous":
            continuous_mode = True
        elif sys.argv[1].startswith("--interval="):
            continuous_mode = True
            try:
                check_interval = int(sys.argv[1].split("=")[1])
            except ValueError:
                print("Error: Invalid interval value")
                sys.exit(1)
        else:
            start_from_run_id = sys.argv[1]
            print(
                f"Using starting run ID from command line: {start_from_run_id} (will skip this run but scan builds before and after)"
            )

    # Configuration
    repo = "cargo-bins/cargo-quickinstall"
    max_builds = 10  # Maximum number of Windows builds to scan
    max_pages = 5  # Maximum pages to search

    # Get API keys
    vt_api_key = os.getenv("VIRUSTOTAL_API_KEY")
    github_token = os.getenv("GITHUB_TOKEN")  # Optional, for higher rate limits

    if not vt_api_key:
        print("Error: VIRUSTOTAL_API_KEY environment variable is required")
        print("Please set it in your .env file or environment")
        sys.exit(1)

    scanner = GitHubArtifactScanner(vt_api_key, github_token)

    if continuous_mode:
        # Run continuous scanning
        scanner.continuous_scan(repo, check_interval)
        return

    if start_from_run_id:
        print(
            f"Starting virus scan of Windows builds from {repo} (starting from run {start_from_run_id} but excluding that run)"
        )
    else:
        print(
            f"Starting virus scan of Windows builds from {repo} (scanning all recent builds)"
        )

    # Find Windows builds
    try:
        windows_builds = scanner.get_windows_builds(
            repo, max_builds, max_pages, start_from_run_id
        )
        if not windows_builds:
            print("No Windows builds found!")
            sys.exit(0)
    except Exception as e:
        print(f"Error finding Windows builds: {e}")
        sys.exit(1)

    # Scan all found builds
    print(f"\nStarting scan of {len(windows_builds)} Windows builds...")
    try:
        results = scanner.scan_multiple_runs(repo, windows_builds)
    except Exception as e:
        print(f"Error during scanning: {e}")
        sys.exit(1)

    # Add results to scanner
    scanner.all_results.extend(results)
    for build in windows_builds:
        build_id = str(build["id"])  # Ensure it's a string
        scanner.scanned_builds.add(build_id)

    # Generate final report
    print("\n" + "=" * 60)
    print("FINAL VIRUS SCAN REPORT")
    print("=" * 60)

    total_scanned = len(results)
    flagged_count = sum(1 for r in results if not r.is_safe)
    clean_count = total_scanned - flagged_count

    print(f"Windows builds scanned: {len(windows_builds)}")
    print(f"Total files scanned: {total_scanned}")
    print(f"Clean files: {clean_count}")
    print(f"Flagged files: {flagged_count}")

    if flagged_count > 0:
        print("\nFLAGGED FILES:")
        for result in results:
            if not result.is_safe:
                print(f"🚨 {result.filename}")
                print(f"   Build: {result.build_id} ({result.build_name})")
                print(f"   SHA256: {result.sha256}")
                print(
                    f"   Malicious: {result.malicious}, Suspicious: {result.suspicious}"
                )
                print(f"   Report: {result.scan_url}")
                print()

    # Save detailed report
    scanner.save_report(repo)

    # Exit with error code if any files were flagged
    if flagged_count > 0:
        print(f"\n⚠️  {flagged_count} files were flagged as potentially malicious!")
        sys.exit(1)

    print("\n✅ All scanned files are clean!")
    sys.exit(0)


if __name__ == "__main__":
    main()
