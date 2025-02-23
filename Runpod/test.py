import os
import subprocess
import time
import signal
import re

POD_NAME = "open-webui-pod"
VOLUME_NAME = "openwebui-storage"
VOLUME_SIZE = 50  # GB
GPU_TYPE = "NVIDIA-RTX-3090"
IMAGE_NAME = "ghcr.io/open-webui/open-webui:ollama"

def run_command(cmd):
    """Runs a shell command and returns the output."""
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running command: {cmd}")
        print(result.stderr)
        return None
    return result.stdout.strip()

def create_network_volume():
    """Creates a network volume if it doesn't already exist."""
    existing_volumes = run_command("runpodctl get volumes")
    if existing_volumes and VOLUME_NAME in existing_volumes:
        print(f"Volume '{VOLUME_NAME}' already exists.")
        return

    print(f"Creating network volume '{VOLUME_NAME}'...")
    run_command(f"runpodctl create volume --name {VOLUME_NAME} --size {VOLUME_SIZE}")

def create_pod():
    """Creates a new RunPod instance with SSH-only access."""
    print("Creating pod...")
    run_command(f"""
        runpodctl create pod \
        --name {POD_NAME} \
        --imageName {IMAGE_NAME} \
        --gpuType {GPU_TYPE} \
        --gpuCount 1 \
        --containerDiskSize 40 \
        --networkVolumeId {VOLUME_NAME} \
        --volumePath /root/.ollama \
        --volumePath /app/backend/data \
        --args "--gpus=all --restart=always"
    """)

def get_pod_id():
    """Gets the pod ID by parsing 'runpodctl get pod' output."""
    pods_output = run_command("runpodctl get pod")
    if not pods_output:
        return None

    # Look for the line containing our pod name and extract the ID
    for line in pods_output.split("\n"):
        if POD_NAME in line:
            match = re.search(r"([a-f0-9\-]+)", line)  # Extract the first UUID (Pod ID)
            if match:
                return match.group(1)
    return None

def wait_for_pod_ready(pod_id):
    """Waits until the pod is running."""
    print("Waiting for pod to become active...")
    while True:
        pod_info = run_command(f"runpodctl get pod {pod_id}")
        if not pod_info:
            continue
        if "RUNNING" in pod_info:
            print("Pod is now running!")
            return
        time.sleep(10)

def get_ssh_command(pod_id):
    """Retrieves the SSH command by parsing 'runpodctl get pod' output."""
    pod_info = run_command(f"runpodctl get pod {pod_id}")
    if not pod_info:
        return None

    ssh_match = re.search(r"(ssh -i .*? runpod@.*? -p \d+)", pod_info)
    return ssh_match.group(1) if ssh_match else None

def setup_ssh_tunnel(ssh_cmd):
    """Creates an SSH tunnel for accessing Open-WebUI and Ollama API."""
    print("\nSetting up SSH tunnel...")
    ssh_tunnel_cmd = f"{ssh_cmd} -N -L 3000:localhost:3000 -L 11434:localhost:11434"
    print(f"\nRun the following command in another terminal:\n{ssh_tunnel_cmd}\n")
    return subprocess.Popen(ssh_tunnel_cmd, shell=True)

def cleanup(pod_id):
    """Stops and deletes the RunPod instance."""
    print("\nStopping and deleting the pod...")
    run_command(f"runpodctl stop pod {pod_id}")
    run_command(f"runpodctl delete pod {pod_id}")
    print("Pod deleted. Exiting.")

if __name__ == "__main__":
    try:
        # Step 1: Create persistent storage
        create_network_volume()

        # Step 2: Create the pod
        create_pod()

        # Step 3: Get the pod ID
        pod_id = None
        while not pod_id:
            time.sleep(5)
            pod_id = get_pod_id()
        
        # Step 4: Wait for the pod to be ready
        wait_for_pod_ready(pod_id)

        # Step 5: Retrieve SSH command
        ssh_command = get_ssh_command(pod_id)
        if not ssh_command:
            print("Failed to get SSH command. Exiting.")
            exit(1)

        # Step 6: Set up SSH tunnel
        ssh_process = setup_ssh_tunnel(ssh_command)

        # Step 7: Keep the script running until user terminates it
        print("\nPress Ctrl+C to terminate and delete the pod.")
        while True:
            time.sleep(5)

    except KeyboardInterrupt:
        print("\nReceived termination signal. Cleaning up...")
        if pod_id:
            cleanup(pod_id)
        if ssh_process:
            ssh_process.terminate()
        print("Goodbye!")
