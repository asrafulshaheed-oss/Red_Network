using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

class DeleteAll
{
    [DllImport("kernel32.dll")]
    static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);

    const int SW_HIDE = 0;
    const int MOVEFILE_DELAY_UNTIL_REBOOT = 0x4;

    private const int OverwritePasses = 3;
    private const int BufferSize = 1024 * 1024; // 1 MB
    private static readonly List<string> FailedPaths = new List<string>();
    private static string _selfPath;

    static int Main()
    {
        // --- 1. Require administrator ---
        if (!IsAdministrator())
        {
            Console.ForegroundColor = ConsoleColor.Yellow;
            Console.WriteLine("This tool must run as Administrator.");
            Console.WriteLine("Right-click the executable and choose 'Run as administrator'.");
            return 1;
        }

        _selfPath = Path.GetFullPath(Process.GetCurrentProcess().MainModule.FileName);

        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine("!!! WARNING !!!");
        Console.WriteLine("This will PERMANENTLY destroy:");
        Console.WriteLine(@"  - Everything under C:\Users");
        Console.WriteLine(@"  - Everything on every fixed and removable drive root (D:\, E:\, ...)");
        Console.WriteLine("  - Volume Shadow Copies on all drives");
        Console.WriteLine("  - Free space on all drives via cipher /w");
        Console.ResetColor();
        Console.WriteLine();
        Console.ForegroundColor = ConsoleColor.Yellow;
        Console.WriteLine("Type  DELETE EVERYTHING  (exact case) and press Enter to proceed:");
        string confirmation = Console.ReadLine();

        if (!string.Equals(confirmation, "DELETE EVERYTHING", StringComparison.Ordinal))
        {
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine("Aborted. Nothing was touched.");
            return 0;
        }

        // --- 2. Hide console after confirmation ---
        var handle = GetConsoleWindow();
        ShowWindow(handle, SW_HIDE);
        Console.SetOut(TextWriter.Null);

        // --- 3. Delete shadow copies FIRST (before cipher, before file deletion) ---
        var volumes = DetectVolumes();
        foreach (var v in volumes)
        {
            DeleteShadowCopies(v.VolumeRoot);
        }

        // --- 4. Process each volume ---
        foreach (var v in volumes)
        {
            if (Directory.Exists(v.TargetPath))
            {
                DeleteTreeSafely(v.TargetPath);
            }

            // cipher /w wipes deallocated clusters on the volume root
            RunCipher(v.VolumeRoot);
        }

        // --- 5. Log failures (invisible to user, but present if needed) ---
        WriteFailureLog();

        // --- 6. Exit silently ---
        return 0;
    }

    // =====================================================================
    //  ADMIN CHECK
    // =====================================================================
    static bool IsAdministrator()
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    }

    // =====================================================================
    //  VOLUME DETECTION  (reports skipped BitLocker volumes)
    // =====================================================================
    static List<(string VolumeRoot, string TargetPath)> DetectVolumes()
    {
        var result = new List<(string, string)>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var drive in DriveInfo.GetDrives())
        {
            try
            {
                if (drive.DriveType != DriveType.Fixed && drive.DriveType != DriveType.Removable)
                    continue;

                string root = drive.RootDirectory.FullName;
                if (string.IsNullOrEmpty(root) || !seen.Add(root))
                    continue;

                if (!drive.IsReady)
                {
                    // Likely a locked BitLocker volume or media-less card reader
                    FailedPaths.Add($"[SKIPPED VOLUME] {root} — not ready (locked BitLocker or no media)");
                    continue;
                }

                string target = root.Equals(@"C:\", StringComparison.OrdinalIgnoreCase)
                    ? @"C:\Users"
                    : root;

                result.Add((root, target));
            }
            catch (Exception ex)
            {
                FailedPaths.Add($"[VOLUME ENUM] {drive.Name}: {ex.Message}");
            }
        }

        return result;
    }

    // =====================================================================
    //  SHADOW COPY DELETION
    // =====================================================================
    static void DeleteShadowCopies(string volumeRoot)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "vssadmin.exe",
                Arguments = $"delete shadows /for={volumeRoot.TrimEnd('\\')} /all /quiet",
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
                p.WaitForExit(120_000);
            }
        }
        catch (Exception ex)
        {
            FailedPaths.Add($"[VSS] {volumeRoot}: {ex.Message}");
        }
    }

    // =====================================================================
    //  SAFE TREE DELETION  (skips reparse points, handles long paths)
    // =====================================================================
    static void DeleteTreeSafely(string rootPath)
    {
        var dirsToDelete = new List<string>();
        var stack = new Stack<string>();
        stack.Push(ToLongPath(rootPath));

        while (stack.Count > 0)
        {
            string current = stack.Pop();
            dirsToDelete.Add(current);

            // --- Files in this directory ---
            string[] files;
            try { files = Directory.GetFiles(current); }
            catch (Exception ex)
            {
                FailedPaths.Add($"[ENUM FILES] {current}: {ex.Message}");
                files = Array.Empty<string>();
            }

            foreach (var f in files)
                SecureDeleteFile(f);

            // --- Subdirectories (SKIP reparse points) ---
            string[] subs;
            try { subs = Directory.GetDirectories(current); }
            catch (Exception ex)
            {
                FailedPaths.Add($"[ENUM DIRS] {current}: {ex.Message}");
                subs = Array.Empty<string>();
            }

            foreach (var d in subs)
            {
                try
                {
                    var attrs = File.GetAttributes(d);
                    if ((attrs & FileAttributes.ReparsePoint) != 0)
                    {
                        // Do NOT recurse. Delete the link itself only.
                        TryDeleteDirectory(d, recurse: false);
                        continue;
                    }
                }
                catch (Exception ex)
                {
                    FailedPaths.Add($"[ATTRS] {d}: {ex.Message}");
                    continue;
                }

                stack.Push(d);
            }
        }

        // Delete directories deepest-first
        for (int i = dirsToDelete.Count - 1; i >= 0; i--)
        {
            string d = dirsToDelete[i];
            if (string.Equals(d, ToLongPath(rootPath), StringComparison.OrdinalIgnoreCase))
                continue;
            TryDeleteDirectory(d, recurse: false);
        }
    }

    static void TryDeleteDirectory(string path, bool recurse)
    {
        try
        {
            var di = new DirectoryInfo(path);
            if (!di.Exists) return;

            var attrs = di.Attributes;
            if ((attrs & FileAttributes.ReadOnly) != 0) attrs &= ~FileAttributes.ReadOnly;
            if ((attrs & FileAttributes.Hidden) != 0) attrs &= ~FileAttributes.Hidden;
            if ((attrs & FileAttributes.System) != 0) attrs &= ~FileAttributes.System;
            if (attrs != di.Attributes) di.Attributes = attrs;

            Directory.Delete(ToLongPath(path), recurse);
        }
        catch (Exception ex)
        {
            FailedPaths.Add($"[RMDIR] {path}: {ex.Message}");
        }
    }

    // =====================================================================
    //  SECURE FILE OVERWRITE + DELETE
    // =====================================================================
    static void SecureDeleteFile(string path)
    {
        string longPath = ToLongPath(path);

        // Never delete our own executable
        try
        {
            if (string.Equals(Path.GetFullPath(path), _selfPath, StringComparison.OrdinalIgnoreCase))
            {
                FailedPaths.Add($"[SELF] Skipped own executable: {path}");
                return;
            }
        }
        catch { }

        try
        {
            var fi = new FileInfo(longPath);
            if (!fi.Exists) return;

            // Clear restrictive attributes
            var attrs = fi.Attributes;
            if ((attrs & FileAttributes.ReadOnly) != 0) attrs &= ~FileAttributes.ReadOnly;
            if ((attrs & FileAttributes.Hidden) != 0) attrs &= ~FileAttributes.Hidden;
            if ((attrs & FileAttributes.System) != 0) attrs &= ~FileAttributes.System;
            if (attrs != fi.Attributes) fi.Attributes = attrs;

            long length = fi.Length;
            if (length > 0)
            {
                using (var fs = new FileStream(longPath, FileMode.Open, FileAccess.Write,
                                               FileShare.None, BufferSize,
                                               FileOptions.SequentialScan))
                {
                    var buffer = new byte[BufferSize];
                    using var rng = RandomNumberGenerator.Create();

                    for (int pass = 0; pass < OverwritePasses; pass++)
                    {
                        fs.Seek(0, SeekOrigin.Begin);
                        long remaining = length;
                        while (remaining > 0)
                        {
                            int chunk = (int)Math.Min(BufferSize, remaining);
                            rng.GetBytes(buffer, 0, chunk);
                            fs.Write(buffer, 0, chunk);
                            remaining -= chunk;
                        }
                        fs.Flush(true); // FlushFileBuffers — forces to physical device
                    }

                    fs.SetLength(0);
                    fs.Flush(true);
                }
            }

            File.Delete(longPath);
        }
        catch (Exception ex)
        {
            // Fallback 1: schedule deletion on next reboot
            if (ScheduleDeleteOnReboot(path))
            {
                FailedPaths.Add($"[REBOOT-DELETE] {path} — locked; scheduled for reboot");
            }
            else
            {
                // Fallback 2: at least attempt a plain delete
                try { File.Delete(longPath); }
                catch { }

                FailedPaths.Add($"[FILE] {path}: {ex.Message}");
            }
        }
    }

    // =====================================================================
    //  REBOOT-PENDING DELETE (MoveFileEx)
    // =====================================================================
    static bool ScheduleDeleteOnReboot(string path)
    {
        try
        {
            // MoveFileEx with DELAY_UNTIL_REBOOT and null destination schedules deletion
            return MoveFileEx(path, null, MOVEFILE_DELAY_UNTIL_REBOOT);
        }
        catch { return false; }
    }

    // =====================================================================
    //  CIPHER  (with exit-code awareness)
    // =====================================================================
    static void RunCipher(string volumeRoot)
    {
        try
        {
            string drive = volumeRoot.TrimEnd('\\');
            var psi = new ProcessStartInfo
            {
                FileName = "cipher.exe",
                Arguments = $"/w:{drive}",
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

                if (!p.WaitForExit(30 * 60 * 1000)) // 30 min timeout
                {
                    try { p.Kill(); } catch { }
                    FailedPaths.Add($"[CIPHER] {volumeRoot}: timed out");
                }
                else if (p.ExitCode != 0)
                {
                    FailedPaths.Add($"[CIPHER] {volumeRoot}: exit code {p.ExitCode}");
                }
            }
        }
        catch (Exception ex)
        {
            FailedPaths.Add($"[CIPHER] {volumeRoot}: {ex.Message}");
        }
    }

    // =====================================================================
    //  LONG-PATH HELPER  (idempotent, handles \\?\ and \\?\UNC\)
    // =====================================================================
    static string ToLongPath(string path)
    {
        if (string.IsNullOrEmpty(path)) return path;

        // Already a long path (device path or UNC device path)
        if (path.StartsWith(@"\\?\", StringComparison.Ordinal) ||
            path.StartsWith(@"\\.\", StringComparison.Ordinal))
            return path;

        // UNC path: \\server\share\... -> \\?\UNC\server\share\...
        if (path.StartsWith(@"\\", StringComparison.Ordinal))
            return @"\\?\UNC\" + path.Substring(2);

        // Absolute local path: C:\... -> \\?\C:\...
        if (Path.IsPathRooted(path))
            return @"\\?\" + path;

        // Relative path — resolve to absolute first
        return @"\\?\" + Path.GetFullPath(path);
    }

    // =====================================================================
    //  FAILURE LOG  (written to %TEMP%, not to the wiped volume)
    // =====================================================================
    static void WriteFailureLog()
    {
        if (FailedPaths.Count == 0) return;

        try
        {
            string log = Path.Combine(Path.GetTempPath(), "wiper-failures.log");
            var sb = new StringBuilder();
            sb.AppendLine($"[{DateTime.UtcNow:O}] Wiper failure log ({FailedPaths.Count} entries)");
            foreach (var f in FailedPaths)
                sb.AppendLine(f);
            File.AppendAllText(log, sb.ToString());
        }
        catch { }
    }
}
