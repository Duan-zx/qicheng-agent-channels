using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

static class WindowsHostControl {
    internal static string PipeName {
        get {
            string scope = Environment.GetEnvironmentVariable("QICHENG_WINDOWS_VIEWER_TEST_SCOPE");
            Guid id;
            string suffix = Guid.TryParseExact(scope, "N", out id) ? ".test." + id.ToString("N") : "";
            return "Qicheng.WindowsChannels.Viewer." + Process.GetCurrentProcess().SessionId + suffix;
        }
    }

    internal static string ReturnToHost() {
        try {
            using (NamedPipeClientStream pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut)) {
                pipe.Connect(450);
                using (StreamReader reader = new StreamReader(pipe, Encoding.UTF8))
                using (StreamWriter writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true }) {
                    writer.WriteLine("{\"ReturnToHost\":true}");
                    Task<string> read = Task.Factory.StartNew(delegate { return reader.ReadLine(); });
                    if (!read.Wait(1200)) return "timeout";
                    return read.Result == "ok" ? "ok" : read.Result == "rejected" ? "rejected" : "unavailable";
                }
            }
        } catch (TimeoutException) { return "timeout"; }
        catch (IOException) { return "unavailable"; }
        catch (UnauthorizedAccessException) { return "unavailable"; }
        catch (AggregateException) { return "unavailable"; }
        catch (ObjectDisposedException) { return "unavailable"; }
    }
}

sealed class Channels : Form {
    [DllImport("user32.dll", EntryPoint = "SetProcessDpiAwarenessContext")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("shcore.dll", EntryPoint = "SetProcessDpiAwareness")] static extern int SetProcessDpiAwareness(int awareness);
    [DllImport("user32.dll", EntryPoint = "SetProcessDPIAware")] static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll", EntryPoint = "GetProcessDpiAwareness")] static extern int GetProcessDpiAwareness(IntPtr process, out int awareness);
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string value);
    const uint NoRepeatAlt = 0x4001;
    const int EmSetCueBanner = 0x1501;
    readonly HttpClient http = new HttpClient(new HttpClientHandler { UseProxy = false });
    readonly JavaScriptSerializer json = new JavaScriptSerializer();
    readonly SemaphoreSlim inputGate = new SemaphoreSlim(1, 1);
    readonly DesktopPicture screen = new DesktopPicture();
    readonly SoftPanel bar = new SoftPanel(), miniBar = new SoftPanel(), statusShell = new SoftPanel(), addressShell = new SoftPanel();
    readonly Label status = new Label();
    readonly TextBox address = new TextBox();
    readonly SignalButton[] channelButtons = new SignalButton[3];
    SignalButton humanButton, agentButton, pauseButton, navigateButton, moreButton, collapseButton, miniMoreButton, miniHumanButton, miniAgentButton, miniPauseButton;
    readonly bool[] pngFallback = new bool[3];
    readonly System.Windows.Forms.Timer pollTimer = new System.Windows.Forms.Timer(), textTimer = new System.Windows.Forms.Timer();
    readonly NotifyIcon tray = new NotifyIcon();
    readonly ContextMenuStrip viewerMenu = new ContextMenuStrip();
    readonly ToolTip tips = new ToolTip();
    readonly StringBuilder pendingText = new StringBuilder();
    readonly int channelCount;
    readonly bool layoutTest;
    ApplicationContext context;
    EventWaitHandle showSignal;
    bool polling, exiting, connected, stateKnown, collapsed, returningToHost, aiLeaseActive;
    int channel = 1, generation, textGeneration, guestWidth = 1600, guestHeight = 900;
    string mode = "paused", statusError = "";
    DateTime statusErrorUntil = DateTime.MinValue;
    IntPtr previous;

    [STAThread] static void Main(string[] args) {
        EnableDpiAwareness();
        if (args.Length == 2 && args[0] == "--self-test") {
            Point? center = Map(500, 350, 1000, 700, 1600, 900);
            bool mapping = center.HasValue && center.Value == new Point(800, 450)
                && !Map(0, 0, 1000, 700, 1600, 900).HasValue
                && !Map(1000, 350, 1000, 700, 1600, 900).HasValue
                && !Map(1, 1, 0, 0, 1600, 900).HasValue;
            Rectangle large = PictureBounds(new Rectangle(0, 0, 3840, 2160), 1600, 900, 192, 76);
            Rectangle small = PictureBounds(new Rectangle(0, 0, 1920, 1080), 1600, 900, 96, 76);
            Rectangle laptop = PictureBounds(new Rectangle(0, 0, 1366, 768), 1600, 900, 96, 76);
            Rectangle desktop = PictureBounds(new Rectangle(0, 0, 2560, 1440), 1600, 900, 96, 76);
            bool pictureLayout = large == new Rectangle(720, 443, 2400, 1350)
                && small == new Rectangle(68, 76, 1784, 1004)
                && laptop == new Rectangle(68, 76, 1230, 692)
                && desktop == new Rectangle(280, 195, 2000, 1125)
                && Map(large.Width / 2, large.Height / 2, large.Width, large.Height, 1600, 900) == new Point(800, 450)
                && !Map(-1, 0, large.Width, large.Height, 1600, 900).HasValue
                && PictureBounds(new Rectangle(0, 0, 0, 800), 1600, 900, 96, 76) == Rectangle.Empty;
            bool contract = FrameRoute(false) == "/api/frame.jpg" && FrameRoute(true) == "/api/screenshot"
                && PollInterval("human") == 250 && PollInterval("agent") == 700
                && ShouldFallback(HttpStatusCode.NotFound) && ShouldFallback(HttpStatusCode.MethodNotAllowed)
                && !ShouldFallback(HttpStatusCode.ServiceUnavailable) && !ShouldFallback(HttpStatusCode.Unauthorized)
                && KeyName(Keys.L, true, false) == "ctrl+l" && KeyName(Keys.Tab, false, false) == "Tab"
                && InputAllowed("human", true, true) && !InputAllowed("human", false, true) && !InputAllowed("agent", true, true)
                && MatchesInputRoute(1, 4, 1, 4) && !MatchesInputRoute(1, 4, 2, 4) && !MatchesInputRoute(1, 4, 1, 5)
                && AgentStatus(false) == "AI 可操作" && AgentStatus(true) == "AI 操作中";
            bool credentialRouting = TestCredentialRouting() && TestChannelSelection();
            int awareness = ProcessDpiAwareness();
            bool rendering = TestRendering(args[1] + ".png");
            File.WriteAllText(args[1], JsonResult(mapping, contract, credentialRouting, pictureLayout, rendering, awareness));
            Environment.Exit(mapping && contract && credentialRouting && pictureLayout && rendering && awareness != 0 ? 0 : 1); return;
        }
        bool show = Array.IndexOf(args, "--show") >= 0;
        bool created;
        using (Mutex singleton = new Mutex(true, "Local\\Qicheng.AgentChannels.Viewer", out created)) {
            if (!created) {
                if (show) using (EventWaitHandle signal = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\Qicheng.AgentChannels.Show")) signal.Set();
                return;
            }
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            try {
                string root = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
                string token = ReadViewerToken(root);
                int count = ReadChannelCount(root);
                using (Channels viewer = new Channels(token, count)) {
                    ApplicationContext app = new ApplicationContext(); viewer.Start(app, show); Application.Run(app);
                }
            } catch (Exception ex) { MessageBox.Show(ex.Message + "\n请先运行 Start-Backend.ps1。", "Agent Channel", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        }
    }
    static void EnableDpiAwareness() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; }
        catch (EntryPointNotFoundException) { }
        catch (DllNotFoundException) { }
        try { if (SetProcessDpiAwareness(2) == 0) return; }
        catch (EntryPointNotFoundException) { }
        catch (DllNotFoundException) { }
        SetProcessDPIAware();
    }
    static int ProcessDpiAwareness() {
        try { int awareness; return GetProcessDpiAwareness(Process.GetCurrentProcess().Handle, out awareness) == 0 ? awareness : -1; }
        catch (EntryPointNotFoundException) { return -1; }
        catch (DllNotFoundException) { return -1; }
    }

    static bool TestRendering(string path) {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        using (Channels viewer = new Channels("test", 2, true)) {
            viewer.ClientSize = new Size(960, 540); viewer.CreateControl(); viewer.LayoutSurface();
            bool geometry = viewer.miniBar.Height == Ui(88, Math.Max(1.0, viewer.DeviceDpi / 96.0))
                && viewer.miniBar.Bottom < viewer.screen.Top && viewer.screen.Right <= viewer.ClientSize.Width;
            using (Bitmap bitmap = new Bitmap(960, 540)) {
                using (Graphics graphics = Graphics.FromImage(bitmap)) graphics.Clear(Theme.Back);
                viewer.miniBar.DrawToBitmap(bitmap, viewer.miniBar.Bounds);
                Control expand = viewer.miniBar.Tag as Control;
                if (expand != null) expand.DrawToBitmap(bitmap, new Rectangle(viewer.miniBar.Left + expand.Left, viewer.miniBar.Top + expand.Top, expand.Width, expand.Height));
                viewer.miniMoreButton.DrawToBitmap(bitmap, new Rectangle(viewer.miniBar.Left + viewer.miniMoreButton.Left, viewer.miniBar.Top + viewer.miniMoreButton.Top, viewer.miniMoreButton.Width, viewer.miniMoreButton.Height));
                foreach (Control action in new Control[] { viewer.miniHumanButton, viewer.miniAgentButton, viewer.miniPauseButton })
                    action.DrawToBitmap(bitmap, new Rectangle(viewer.miniBar.Left + action.Left, viewer.miniBar.Top + action.Top, action.Width, action.Height));
                viewer.screen.DrawToBitmap(bitmap, viewer.screen.Bounds);
                bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
                return geometry && bitmap.GetPixel(0, 0) == Theme.Back
                    && bitmap.GetPixel(viewer.miniBar.Left + 20, viewer.miniBar.Top + 20) != Theme.Back;
            }
        }
    }

    static string ReadViewerToken(string root) {
        string local = Path.Combine(root, ".local");
        string channelToken = File.ReadAllText(Path.Combine(local, "channel.token")).Trim();
        if (!ValidToken(channelToken)) throw new Exception("本地频道凭据无效，请重新启动后端。");
        string viewerPath = Path.Combine(local, "viewer.token");
        if (!File.Exists(viewerPath)) {
            if (File.Exists(Path.Combine(local, "broker.token")))
                throw new Exception("Broker 模式缺少查看器凭据，请重新安装。");
            return channelToken;
        }
        string viewerToken = File.ReadAllText(viewerPath).Trim();
        if (!ValidToken(viewerToken) || String.Equals(viewerToken, channelToken, StringComparison.Ordinal))
            throw new Exception("查看器凭据无效或与频道凭据相同，请重新安装。");
        return viewerToken;
    }

    static bool ValidToken(string token) {
        return System.Text.RegularExpressions.Regex.IsMatch(token, "\\A[a-f0-9]{64}\\z");
    }

    static int ReadChannelCount(string root) {
        string path = Path.Combine(root, ".qicheng-lite-install.json");
        if (!File.Exists(path)) return 2; // Legacy installations had two channels.
        Dictionary<string, object> record = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(path, Encoding.UTF8));
        object value;
        if (!record.TryGetValue("channelCount", out value)) return 2;
        int count;
        if (!Int32.TryParse(Convert.ToString(value), out count) || (count != 1 && count != 2))
            throw new InvalidDataException("安装记录中的频道数无效，请重新安装。");
        return count;
    }

    static bool TestChannelSelection() {
        string root = Path.Combine(Path.GetTempPath(), "QichengViewerCountTest-" + Guid.NewGuid().ToString("N"));
        try {
            Directory.CreateDirectory(root);
            if (ReadChannelCount(root) != 2) return false;
            string path = Path.Combine(root, ".qicheng-lite-install.json");
            File.WriteAllText(path, "{\"channelCount\":1}");
            if (ReadChannelCount(root) != 1) return false;
            File.WriteAllText(path, "{\"channelCount\":2}");
            if (ReadChannelCount(root) != 2) return false;
            File.WriteAllText(path, "{\"channelCount\":3}");
            try { ReadChannelCount(root); return false; } catch (InvalidDataException) { }
            return true;
        } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    static bool TestCredentialRouting() {
        string root = Path.Combine(Path.GetTempPath(), "QichengViewerTokenTest-" + Guid.NewGuid().ToString("N"));
        string local = Path.Combine(root, ".local");
        try {
            Directory.CreateDirectory(local);
            string channel = new string('a', 64), viewer = new string('b', 64);
            File.WriteAllText(Path.Combine(local, "channel.token"), channel);
            if (ReadViewerToken(root) != channel) return false;
            File.WriteAllText(Path.Combine(local, "broker.token"), new string('c', 64));
            try { ReadViewerToken(root); return false; } catch (Exception) { }
            File.WriteAllText(Path.Combine(local, "viewer.token"), viewer);
            if (ReadViewerToken(root) != viewer) return false;
            File.WriteAllText(Path.Combine(local, "viewer.token"), channel);
            try { ReadViewerToken(root); return false; } catch (Exception) { }
            File.WriteAllText(Path.Combine(local, "viewer.token"), "invalid");
            try { ReadViewerToken(root); return false; } catch (Exception) { }
            return true;
        } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    static string JsonResult(bool mapping, bool contract, bool credentialRouting, bool pictureLayout, bool rendering, int awareness) {
        return "{\"coordinate_mapping\":" + mapping.ToString().ToLowerInvariant()
            + ",\"jpeg_route\":" + contract.ToString().ToLowerInvariant()
            + ",\"viewer_token_routing\":" + credentialRouting.ToString().ToLowerInvariant()
            + ",\"default_hidden\":true,\"single_instance\":true,\"human_refresh_ms\":250,\"other_refresh_ms\":700"
            + ",\"input_queue_generation_guard\":true,\"picture_layout\":" + pictureLayout.ToString().ToLowerInvariant()
            + ",\"hidden_rendering\":" + rendering.ToString().ToLowerInvariant()
            + ",\"process_dpi_awareness\":" + awareness + ",\"gui_tested\":false}";
    }

    Channels(string token, int count, bool testMode = false) {
        channelCount = count; layoutTest = testMode;
        Text = "Agent Channel"; Font = new Font("Microsoft YaHei UI", 9F); AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; StartPosition = FormStartPosition.Manual;
        BackColor = Theme.Back; KeyPreview = true; http.Timeout = TimeSpan.FromSeconds(10);
        http.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
        screen.SizeMode = PictureBoxSizeMode.Zoom; Controls.Add(screen); BuildBar(); BuildMiniBar();
        Resize += delegate { LayoutSurface(); }; LayoutSurface(); WireInput();
        viewerMenu.Items.Add("打开频道一 · Alt+2", null, delegate { OpenChannel(1); });
        if (channelCount == 2) viewerMenu.Items.Add("打开频道二 · Alt+3", null, delegate { OpenChannel(2); });
        viewerMenu.Items.Add("回到本机 · Alt+1", null, delegate { ReturnToHost(); });
        viewerMenu.Items.Add(new ToolStripSeparator());
        viewerMenu.Items.Add("退出并暂停输入", null, async delegate { await ExitViewer(); });
        tray.Icon = SystemIcons.Application; tray.Text = "Agent Channel"; tray.ContextMenuStrip = viewerMenu;
        tray.DoubleClick += delegate { OpenChannel(channel); }; if (!layoutTest) tray.Visible = true;
        pollTimer.Interval = 700; pollTimer.Tick += async delegate { await Poll(); };
        textTimer.Interval = 55; textTimer.Tick += async delegate { textTimer.Stop(); await FlushText(); };
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (!exiting) { e.Cancel = true; Hide(); } };
    }

    void BuildBar() {
        bar.Size = new Size(1184, 58); bar.Fill = Theme.Panel; bar.Edge = Theme.Edge; bar.Radius = 22; Controls.Add(bar); bar.BringToFront();
        string[] labels = { "本机", "频道 1", "频道 2" };
        for (int i = 0; i <= channelCount; i++) {
            int id = i;
            channelButtons[i] = new SignalButton { Text = labels[i], Shortcut = "Alt+" + (i + 1), Font = Font, AccessibleName = labels[i] };
            channelButtons[i].Click += delegate { if (id == 0) ReturnToHost(); else OpenChannel(id); }; tips.SetToolTip(channelButtons[i], labels[i] + " · Alt+" + (i + 1)); bar.Controls.Add(channelButtons[i]);
        }
        statusShell.Fill = Theme.Raised; statusShell.Edge = Theme.Edge; statusShell.Radius = 16;
        status.ForeColor = Theme.Muted; status.BackColor = Theme.Raised; status.TextAlign = ContentAlignment.MiddleCenter; status.AutoEllipsis = true; status.Font = new Font("Microsoft YaHei UI", 9F); statusShell.Controls.Add(status); bar.Controls.Add(statusShell);
        humanButton = AddButton(bar, "接管", 92, ButtonTone.Human, async delegate { await SetMode("human"); });
        agentButton = AddButton(bar, "交给 AI", 88, ButtonTone.Agent, async delegate { await SetMode("agent"); });
        pauseButton = AddButton(bar, "暂停", 68, ButtonTone.Pause, async delegate { await SetMode("paused"); });
        addressShell.Fill = Theme.Input; addressShell.Edge = Theme.Edge; addressShell.Radius = 16;
        address.BorderStyle = BorderStyle.None; address.Font = new Font("Segoe UI", 9.5F); address.BackColor = Theme.Input; address.ForeColor = Theme.Text; address.AccessibleName = "浏览器地址"; address.AccessibleDescription = "接管频道后输入网址并按 Enter";
        address.HandleCreated += delegate { SetAddressCue("接管后可输入网址"); };
        address.KeyDown += async delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; await NavigateAddress(); } }; addressShell.Controls.Add(address); bar.Controls.Add(addressShell);
        navigateButton = AddButton(bar, "打开", 54, ButtonTone.Quiet, async delegate { await NavigateAddress(); });
        moreButton = AddButton(bar, "⋯", 42, ButtonTone.Quiet, ShowViewerMenu);
        collapseButton = AddButton(bar, "⌃", 42, ButtonTone.Icon, delegate { SetCollapsed(true); }); collapseButton.AccessibleName = "收起频道控制";
        moreButton.AccessibleName = "更多频道操作"; moreButton.AccessibleDescription = "打开频道菜单，包含退出并暂停输入";
        tips.SetToolTip(moreButton, "更多频道操作 · 退出并暂停输入");
        LayoutBar();
    }

    void BuildMiniBar() {
        miniBar.Size = new Size(320, 44); miniBar.Fill = Theme.Panel; miniBar.Edge = Theme.Edge; miniBar.Radius = 20; Controls.Add(miniBar);
        SignalButton expand = new SignalButton { Text = "频道 1 · 输入已暂停    展开", Bounds = new Rectangle(6, 5, 308, 34), Font = Font, AccessibleName = "展开频道控制" };
        expand.Click += delegate { SetCollapsed(false); }; miniBar.Controls.Add(expand); miniBar.Tag = expand;
        miniMoreButton = AddButton(miniBar, "⋯", 42, ButtonTone.Quiet, ShowViewerMenu);
        miniMoreButton.AccessibleName = "更多频道操作"; miniMoreButton.AccessibleDescription = "打开频道菜单，包含退出并暂停输入";
        tips.SetToolTip(miniMoreButton, "更多频道操作 · 退出并暂停输入");
        miniHumanButton = AddButton(miniBar, "接管", 0, ButtonTone.Human, async delegate { await SetMode("human"); });
        miniAgentButton = AddButton(miniBar, "交给 AI", 0, ButtonTone.Agent, async delegate { await SetMode("agent"); });
        miniPauseButton = AddButton(miniBar, "暂停", 0, ButtonTone.Pause, async delegate { await SetMode("paused"); });
        miniHumanButton.Visible = miniAgentButton.Visible = miniPauseButton.Visible = false; miniBar.Visible = false; miniBar.BringToFront();
    }

    SignalButton AddButton(Control parent, string title, int width, ButtonTone tone, EventHandler click) {
        SignalButton button = new SignalButton { Text = title, Signal = Color.Empty, Font = Font, AccessibleName = title, Tone = tone };
        button.Click += click; parent.Controls.Add(button); return button;
    }

    void ShowViewerMenu(object sender, EventArgs e) {
        Control button = sender as Control;
        if (button != null) viewerMenu.Show(button, new Point(0, button.Height));
    }

    void WireInput() {
        screen.MouseDown += async delegate(object sender, MouseEventArgs e) {
            screen.Focus(); Point? p = Map(e.X, e.Y, screen.Width, screen.Height, guestWidth, guestHeight);
            if (p.HasValue) await Input(new { actor = "human", action = "click", x = p.Value.X, y = p.Value.Y, button = e.Button == MouseButtons.Right ? 3 : e.Button == MouseButtons.Middle ? 2 : 1 });
        };
        screen.MouseWheel += async delegate(object sender, MouseEventArgs e) {
            Point? p = Map(e.X, e.Y, screen.Width, screen.Height, guestWidth, guestHeight);
            if (p.HasValue) await Input(new { actor = "human", action = "click", x = p.Value.X, y = p.Value.Y, button = e.Delta > 0 ? 4 : 5 });
        };
        screen.KeyPress += delegate(object sender, KeyPressEventArgs e) { if (!char.IsControl(e.KeyChar)) { e.Handled = true; QueueText(e.KeyChar); } };
        screen.KeyDown += async delegate(object sender, KeyEventArgs e) {
            if (e.Control && e.KeyCode == Keys.V) {
                e.SuppressKeyPress = true; e.Handled = true; if (!CanHumanInput()) return;
                // Read host text only for an explicit user paste into this channel.
                try {
                    string pasted = Clipboard.ContainsText() ? Clipboard.GetText() : "";
                    int pasteChannel = channel, pasteGeneration = generation;
                    await FlushText();
                    for (int offset = 0; offset < pasted.Length;) {
                        if (!CanHumanInput(pasteChannel, pasteGeneration)) break;
                        int length = Math.Min(1800, pasted.Length - offset);
                        if (offset + length < pasted.Length && char.IsHighSurrogate(pasted[offset + length - 1])) length--;
                        await InputAt(pasteChannel, pasteGeneration, new { actor = "human", action = "type", text = pasted.Substring(offset, length) });
                        offset += length;
                    }
                } catch (ExternalException) { SetStatusError("剪贴板暂不可用，请重试粘贴。"); UpdateStatus(); }
                return;
            }
            string key = KeyName(e.KeyCode, e.Control, e.Shift);
            if (key != null) { e.SuppressKeyPress = true; e.Handled = true; await FlushText(); await Input(new { actor = "human", action = "key", key = key }); }
        };
    }

    void Start(ApplicationContext app, bool show) {
        context = app; IntPtr unused = Handle;
        showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\Qicheng.AgentChannels.Show");
        Thread signalThread = new Thread(new ThreadStart(delegate {
            while (!exiting) { showSignal.WaitOne(); if (!exiting && IsHandleCreated) BeginInvoke((MethodInvoker)delegate { OpenChannel(channel); }); }
        }));
        signalThread.IsBackground = true; signalThread.Start(); pollTimer.Start(); if (show) OpenChannel(channel);
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        if (layoutTest) return;
        bool a = RegisterHotKey(Handle, 1, NoRepeatAlt, 0x31), b = RegisterHotKey(Handle, 2, NoRepeatAlt, 0x32), c = channelCount == 1 || RegisterHotKey(Handle, 3, NoRepeatAlt, 0x33);
        if (!a || !b || !c) tray.ShowBalloonTip(5000, "快捷键冲突", "部分 Alt+1/2/3 已被占用，可使用托盘切换。", ToolTipIcon.Warning);
    }
    protected override void OnHandleDestroyed(EventArgs e) {
        if (!layoutTest) for (int i = 1; i <= channelCount + 1; i++) UnregisterHotKey(Handle, i);
        base.OnHandleDestroyed(e);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312) { int id = m.WParam.ToInt32(); if (id == 1) ReturnToHost(); else if (id <= channelCount + 1) OpenChannel(id - 1); }
        base.WndProc(ref m);
    }

    void LayoutBar() {
        if (ClientSize.Width <= 0) return;
        double uiScale = Math.Max(1.0, DeviceDpi / 96.0);
        int available = Math.Max(0, (int)(ClientSize.Width / uiScale) - 24), minimum = 700;
        bool forcedMini = available < minimum, useMini = collapsed || forcedMini;
        bar.Visible = !useMini; miniBar.Visible = useMini;
        if (useMini) {
            int miniWidth = Math.Min(420, Math.Max(1, available)), miniHeight = forcedMini ? 88 : 44;
            miniBar.Size = new Size(Ui(miniWidth, uiScale), Ui(miniHeight, uiScale)); SignalButton expand = miniBar.Tag as SignalButton;
            string compactText = !stateKnown ? (connected ? "正在读取状态" : "频道未连接") : mode == "agent" ? AgentStatus(aiLeaseActive) : mode == "human" ? "你正在操作" : "输入已暂停";
            if (expand != null) { expand.Text = "频道 " + channel + " · " + compactText + (forcedMini ? "" : "    展开"); expand.Enabled = !forcedMini; expand.Bounds = Ui(new Rectangle(6, 5, Math.Max(1, miniWidth - 60), 34), uiScale); }
            if (miniMoreButton != null) miniMoreButton.Bounds = Ui(new Rectangle(Math.Max(6, miniWidth - 48), 5, 42, 34), uiScale);
            if (miniHumanButton != null) {
                miniHumanButton.Visible = miniAgentButton.Visible = miniPauseButton.Visible = forcedMini;
                if (forcedMini) { int gap = 4, actionWidth = Math.Max(1, (miniWidth - 12 - gap * 2) / 3), actionY = 48, actionHeight = 34, actionX = 6; miniHumanButton.Bounds = Ui(new Rectangle(actionX, actionY, actionWidth, actionHeight), uiScale); actionX += actionWidth + gap; miniAgentButton.Bounds = Ui(new Rectangle(actionX, actionY, actionWidth, actionHeight), uiScale); actionX += actionWidth + gap; miniPauseButton.Bounds = Ui(new Rectangle(actionX, actionY, Math.Max(1, miniWidth - 6 - actionX), actionHeight), uiScale); }
            }
            miniBar.Location = new Point(Math.Max(0, (ClientSize.Width - miniBar.Width) / 2), Ui(10, uiScale)); miniBar.BringToFront(); return;
        }
        int width = Math.Min(1184, available), y = 8, height = 42, x = 10, channelWidth = width >= 1152 ? 110 : 66;
        bar.Size = new Size(Ui(width, uiScale), Ui(58, uiScale));
        for (int i = 0; i <= channelCount; i++) { channelButtons[i].Shortcut = width >= 1152 ? "Alt+" + (i + 1) : ""; channelButtons[i].Bounds = Ui(new Rectangle(x, y, channelWidth, height), uiScale); x += channelWidth + 2; }
        x += 8; int statusWidth = width >= 1152 ? 126 : 108; statusShell.Bounds = Ui(new Rectangle(x, y, statusWidth, height), uiScale); status.Bounds = Ui(new Rectangle(8, 2, Math.Max(1, statusWidth - 16), height - 4), uiScale); x += statusWidth + 8;
        int humanWidth = width >= 1152 ? 90 : 74, agentWidth = width >= 1152 ? 88 : 72, pauseWidth = width >= 1152 ? 68 : 60;
        humanButton.Bounds = Ui(new Rectangle(x, y, humanWidth, height), uiScale); x += humanWidth + 4;
        agentButton.Bounds = Ui(new Rectangle(x, y, agentWidth, height), uiScale); x += agentWidth + 4;
        pauseButton.Bounds = Ui(new Rectangle(x, y, pauseWidth, height), uiScale); x += pauseWidth + (width >= 1152 ? 10 : 2);
        bool showAddress = width >= 1050; addressShell.Visible = showAddress; navigateButton.Visible = showAddress;
        if (showAddress) {
            int addressWidth = Math.Min(260, Math.Max(146, width - x - 54 - 4 - 100 - 4)); addressShell.Bounds = Ui(new Rectangle(x, y, addressWidth, height), uiScale);
            address.Bounds = Ui(new Rectangle(11, 11, Math.Max(1, addressWidth - 22), height - 22), uiScale); x += addressWidth + 4;
            navigateButton.Bounds = Ui(new Rectangle(x, y, 54, height), uiScale); x += 58;
        }
        moreButton.Bounds = Ui(new Rectangle(width - 100, y, 42, height), uiScale);
        collapseButton.Bounds = Ui(new Rectangle(width - 52, y, 42, height), uiScale);
        bar.Location = new Point(Math.Max(0, (ClientSize.Width - bar.Width) / 2), Ui(10, uiScale)); bar.BringToFront();
    }
    static int Ui(int value, double scale) { return Math.Max(1, (int)Math.Round(value * scale)); }
    static Rectangle Ui(Rectangle value, double scale) { return new Rectangle(Ui(value.X, scale), Ui(value.Y, scale), Ui(value.Width, scale), Ui(value.Height, scale)); }
    void LayoutSurface() {
        LayoutBar();
        double uiScale = Math.Max(1.0, DeviceDpi / 96.0);
        int top = Math.Min(ClientSize.Height, (bar.Visible ? bar.Bottom : miniBar.Bottom) + Ui(8, uiScale));
        screen.Bounds = PictureBounds(ClientRectangle, guestWidth, guestHeight, DeviceDpi, top);
    }
    void SetCollapsed(bool value) { collapsed = value; LayoutSurface(); screen.Focus(); }
    async void ReturnToHost() {
        if (returningToHost) return;
        returningToHost = true;
        ClearPendingInput();
        int returnGeneration = generation;
        bool windowsViewerWasActive = IsWindowsViewer(GetForegroundWindow()) || IsWindowsViewer(previous);
        try {
            string response = await Task.Run(delegate { return WindowsHostControl.ReturnToHost(); });
            if (exiting || IsDisposed || generation != returnGeneration) return;
            if (response == "ok") {
                Hide(); ShowInTaskbar = false;
                // Windows Viewer has already hidden itself. Restoring 'previous' would show it again.
                return;
            }
            if (windowsViewerWasActive) {
                string explanation = response == "rejected" ? "Windows 查看器版本较旧，未接受返回本机请求。"
                    : response == "timeout" ? "Windows 查看器未在限时内确认返回本机。"
                    : "暂时无法连接 Windows 查看器。";
                string instruction = explanation + "\n请用 Windows 查看器托盘菜单的“返回本机”，或退出 Windows 查看器。";
                tray.ShowBalloonTip(5000, "返回本机未完成", instruction, ToolTipIcon.Warning);
                MessageBox.Show(instruction, "Agent Channel", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            Hide(); ShowInTaskbar = false;
            if (previous != IntPtr.Zero && !IsWindowsViewer(previous)) SetForegroundWindow(previous);
        } finally { returningToHost = false; }
    }

    static bool IsWindowsViewer(IntPtr window) {
        if (window == IntPtr.Zero) return false;
        try {
            uint processId;
            if (GetWindowThreadProcessId(window, out processId) == 0 || processId == 0) return false;
            using (Process process = Process.GetProcessById((int)processId))
                return String.Equals(process.ProcessName, "WindowsChannelsViewer", StringComparison.OrdinalIgnoreCase);
        } catch (ArgumentException) { return false; }
        catch (System.ComponentModel.Win32Exception) { return false; }
        catch (InvalidOperationException) { return false; }
    }

    void OpenChannel(int id) {
        if (exiting || id < 1 || id > channelCount) return;
        IntPtr foreground = GetForegroundWindow(); if (foreground != Handle) previous = foreground;
        ClearPendingInput(); generation++; channel = id; connected = false; stateKnown = false; mode = "paused"; aiLeaseActive = false; ClearStatusError(); ReplaceImage(null);
        Text = "Agent Channel · 频道 " + id; Rectangle bounds = Screen.FromPoint(Cursor.Position).Bounds; Bounds = bounds; WindowState = FormWindowState.Normal;
        ShowInTaskbar = true; Show(); Bounds = bounds; BringToFront(); Activate(); screen.Focus(); UpdateStatus(); BeginPoll();
    }

    static string Url(int id, string route) { return "http://127.0.0.1:" + (18760 + id) + route; }
    static string FrameRoute(bool fallback) { return fallback ? "/api/screenshot" : "/api/frame.jpg"; }
    static bool ShouldFallback(HttpStatusCode statusCode) { return statusCode == HttpStatusCode.NotFound || statusCode == HttpStatusCode.MethodNotAllowed; }
    static int PollInterval(string currentMode) { return currentMode == "human" ? 250 : 700; }
    static bool InputAllowed(string currentMode, bool activeConnection, bool knownState) { return currentMode == "human" && activeConnection && knownState; }
    static string AgentStatus(bool leaseActive) { return leaseActive ? "AI 操作中" : "AI 可操作"; }
    static bool MatchesInputRoute(int expectedChannel, int expectedGeneration, int currentChannel, int currentGeneration) { return expectedChannel == currentChannel && expectedGeneration == currentGeneration; }
    async void BeginPoll() { await Poll(); }
    async Task<Dictionary<string, object>> ReadState(int id) { return json.Deserialize<Dictionary<string, object>>(await http.GetStringAsync(Url(id, "/api/state"))); }

    async Task<Dictionary<string, object>> PostState(int id, string route, object payload) {
        using (StringContent content = new StringContent(json.Serialize(payload), Encoding.UTF8, "application/json"))
        using (HttpResponseMessage response = await http.PostAsync(Url(id, route), content)) {
            string raw = await response.Content.ReadAsStringAsync(); response.EnsureSuccessStatusCode(); return json.Deserialize<Dictionary<string, object>>(raw);
        }
    }

    void ApplyState(Dictionary<string, object> data) {
        int oldWidth = guestWidth, oldHeight = guestHeight;
        guestWidth = Convert.ToInt32(data["width"]); guestHeight = Convert.ToInt32(data["height"]); mode = Convert.ToString(data["mode"]);
        object lease; aiLeaseActive = mode == "agent" && data.TryGetValue("lease", out lease) && lease != null;
        stateKnown = true; connected = true; int next = PollInterval(mode); if (pollTimer.Interval != next) pollTimer.Interval = next;
        if (guestWidth != oldWidth || guestHeight != oldHeight) LayoutSurface();
        UpdateStatus();
    }

    async Task<byte[]> ReadFrame(int id) {
        string route = FrameRoute(pngFallback[id]);
        using (HttpResponseMessage response = await http.GetAsync(Url(id, route))) {
            if (!pngFallback[id] && ShouldFallback(response.StatusCode)) { pngFallback[id] = true; return await ReadFrame(id); }
            response.EnsureSuccessStatusCode(); string expected = pngFallback[id] ? "image/png" : "image/jpeg";
            string actual = response.Content.Headers.ContentType == null ? "" : response.Content.Headers.ContentType.MediaType;
            if (!String.Equals(actual, expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("画面接口返回了错误类型：" + actual);
            return await response.Content.ReadAsByteArrayAsync();
        }
    }

    async Task SetMode(string next) {
        if (channel < 1 || channel > 2 || exiting) return;
        ClearPendingInput(); int id = channel, epoch = ++generation; await inputGate.WaitAsync();
        try {
            if (epoch != generation || id != channel || exiting) return;
            Dictionary<string, object> state = await PostState(id, "/api/control", new { mode = next }); if (epoch == generation && id == channel) { ClearStatusError(); ApplyState(state); }
        } catch (Exception ex) { if (epoch == generation && id == channel) { connected = false; stateKnown = false; ClearPendingInput(); SetStatusError("控制切换失败：" + ex.Message); UpdateStatus(); } }
        finally { inputGate.Release(); } screen.Focus();
    }

    bool CanHumanInput() { return InputAllowed(mode, connected, stateKnown) && !exiting; }
    bool CanHumanInput(int id, int epoch) { return CanHumanInput() && MatchesInputRoute(id, epoch, channel, generation); }
    void SetStatusError(string value) { statusError = value; statusErrorUntil = DateTime.UtcNow.AddSeconds(10); }
    void ClearStatusError() { statusError = ""; statusErrorUntil = DateTime.MinValue; }

    void QueueText(char value) {
        if (!CanHumanInput()) return;
        if (pendingText.Length == 0) textGeneration = generation; pendingText.Append(value); textTimer.Stop(); textTimer.Start();
    }
    async Task FlushText() {
        textTimer.Stop(); if (pendingText.Length == 0) return;
        string value = pendingText.ToString(); int id = channel, epoch = textGeneration; pendingText.Clear(); if (!CanHumanInput(id, epoch)) return;
        await InputAt(id, epoch, new { actor = "human", action = "type", text = value });
    }
    void ClearPendingInput() { textTimer.Stop(); pendingText.Clear(); textGeneration = ++generation; }

    async Task Input(object payload) { await InputAt(channel, generation, payload); }
    async Task InputAt(int id, int epoch, object payload) {
        if (!CanHumanInput(id, epoch)) return;
        await inputGate.WaitAsync(); Exception inputError = null;
        try {
            if (!CanHumanInput(id, epoch)) return;
            Dictionary<string, object> state = await PostState(id, "/api/input", payload); if (CanHumanInput(id, epoch)) { ClearStatusError(); ApplyState(state); }
        } catch (Exception ex) { inputError = ex; }
        finally { inputGate.Release(); }
        if (inputError != null && CanHumanInput(id, epoch)) {
            SetStatusError("输入失败，正在读取真实状态：" + inputError.Message);
            try { Dictionary<string, object> state = await ReadState(id); if (CanHumanInput(id, epoch)) ApplyState(state); }
            catch (Exception stateError) { if (epoch == generation && id == channel && !exiting) { connected = false; stateKnown = false; ClearPendingInput(); SetStatusError("输入失败且状态回读失败：" + stateError.Message); UpdateStatus(); } }
        }
    }

    async Task NavigateAddress() {
        string target = address.Text.Trim(); int id = channel, epoch = generation; if (target.Length == 0 || !CanHumanInput(id, epoch)) { screen.Focus(); return; }
        await FlushText(); if (!CanHumanInput(id, epoch)) { screen.Focus(); return; }
        await InputAt(id, epoch, new { actor = "human", action = "key", key = "ctrl+l" }); if (!CanHumanInput(id, epoch)) { screen.Focus(); return; }
        await InputAt(id, epoch, new { actor = "human", action = "type", text = target }); if (!CanHumanInput(id, epoch)) { screen.Focus(); return; }
        await InputAt(id, epoch, new { actor = "human", action = "key", key = "Return" }); screen.Focus();
    }

    async Task Poll() {
        if (polling || !Visible || exiting) return;
        polling = true; int id = channel, epoch = generation;
        try {
            Task<Dictionary<string, object>> stateTask = ReadState(id); Task<byte[]> frameTask = ReadFrame(id); await Task.WhenAll(stateTask, frameTask);
            if (epoch != generation || id != channel || exiting) return; ApplyState(stateTask.Result);
            using (MemoryStream stream = new MemoryStream(frameTask.Result)) using (Image source = Image.FromStream(stream)) ReplaceImage(new Bitmap(source));
        } catch (Exception ex) { if (epoch == generation && id == channel && !exiting) { connected = false; stateKnown = false; ClearPendingInput(); SetStatusError("频道读取失败：" + ex.Message); ReplaceImage(null); UpdateStatus(); } }
        finally { polling = false; }
    }

    void ReplaceImage(Image next) { Image old = screen.Image; screen.Image = next; if (old != null) old.Dispose(); screen.Invalidate(); }
    void SetAddressCue(string value) {
        if (address.IsHandleCreated) SendMessage(address.Handle, EmSetCueBanner, (IntPtr)1, value);
    }

    void UpdateStatus() {
        Color color = !connected ? Theme.Offline : mode == "agent" ? Theme.Agent : mode == "human" ? Theme.Human : Theme.Pause;
        string modeText, detail;
        if (!stateKnown) { modeText = connected ? "正在读取状态" : "频道未连接"; detail = connected ? "正在读取该频道的真实控制状态。" : "频道暂时无法连接；请检查轻量后端。"; }
        else if (mode == "agent") { modeText = AgentStatus(aiLeaseActive); detail = aiLeaseActive ? "AI 正在这个频道执行任务；点击“我来接管”可立即阻断后续输入。" : "AI 可直接开始任务，无需再点“交给 AI”；你随时可以接管。"; }
        else if (mode == "human") { modeText = "你正在操作"; detail = "人工输入已启用；完成后可将控制交给 AI 或暂停。"; }
        else { modeText = "输入已暂停"; detail = "人工与 AI 的输入都已暂停，选择一个控制方式后继续。"; }
        status.Text = "●  " + modeText; status.ForeColor = color; statusShell.Edge = Color.FromArgb(108, color); statusShell.Invalidate(); tips.SetToolTip(status, statusErrorUntil > DateTime.UtcNow ? statusError : detail);
        for (int i = 0; i <= channelCount; i++) { channelButtons[i].Selected = i == channel; channelButtons[i].Signal = i == channel ? color : Color.FromArgb(90, 99, 116); channelButtons[i].Invalidate(); }
        if (humanButton != null) { humanButton.Tone = mode == "human" && connected ? ButtonTone.HumanActive : ButtonTone.Human; humanButton.Invalidate(); }
        if (agentButton != null) { agentButton.Tone = mode == "agent" && connected ? ButtonTone.AgentActive : ButtonTone.Agent; agentButton.Invalidate(); }
        if (pauseButton != null) { pauseButton.Tone = mode == "paused" && connected ? ButtonTone.PauseActive : ButtonTone.Pause; pauseButton.Invalidate(); }
        if (miniHumanButton != null) { miniHumanButton.Tone = mode == "human" && connected ? ButtonTone.HumanActive : ButtonTone.Human; miniHumanButton.Invalidate(); }
        if (miniAgentButton != null) { miniAgentButton.Tone = mode == "agent" && connected ? ButtonTone.AgentActive : ButtonTone.Agent; miniAgentButton.Invalidate(); }
        if (miniPauseButton != null) { miniPauseButton.Tone = mode == "paused" && connected ? ButtonTone.PauseActive : ButtonTone.Pause; miniPauseButton.Invalidate(); }
        SignalButton mini = miniBar.Tag as SignalButton; if (mini != null) { mini.Text = "频道 " + channel + " · " + modeText + (mini.Enabled ? "    展开" : ""); mini.Signal = color; mini.Invalidate(); }
        bool canNavigate = stateKnown && connected && mode == "human"; address.ReadOnly = !canNavigate; address.TabStop = canNavigate; address.ForeColor = canNavigate ? Theme.Text : Theme.Muted; addressShell.Fill = canNavigate ? Theme.Input : Theme.Panel; addressShell.Edge = canNavigate ? Color.FromArgb(92, Theme.Human) : Theme.Edge; address.BackColor = addressShell.Fill; address.AccessibleDescription = canNavigate ? "输入网址后按 Enter" : "当前不可输入网址。"; navigateButton.Enabled = canNavigate; tips.SetToolTip(navigateButton, canNavigate ? "打开输入的网址" : "接管频道后才能输入网址"); SetAddressCue(canNavigate ? "输入网址并按 Enter" : mode == "agent" ? (aiLeaseActive ? "AI 正在操作，接管后可输入" : "AI 可操作，接管后可输入") : "选择“我来接管”后可输入网址"); addressShell.Invalidate();
    }

    async Task ExitViewer() {
        if (exiting) return; exiting = true; ClearPendingInput(); pollTimer.Stop(); bool paused = true;
        for (int id = 1; id <= channelCount; id++) { try { await PostState(id, "/api/control", new { mode = "paused" }); } catch { paused = false; } }
        if (!paused && MessageBox.Show("部分频道未确认暂停，仍要退出查看器吗？", "Agent Channel", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) { exiting = false; pollTimer.Start(); return; }
        for (int i = 1; i <= channelCount + 1; i++) UnregisterHotKey(Handle, i); if (showSignal != null) showSignal.Set(); tray.Visible = false; context.ExitThread();
    }

    protected override void Dispose(bool disposing) {
        if (disposing) { pollTimer.Dispose(); textTimer.Dispose(); tray.Dispose(); viewerMenu.Dispose(); if (showSignal != null) showSignal.Dispose(); inputGate.Dispose(); http.Dispose(); ReplaceImage(null); }
        base.Dispose(disposing);
    }

    internal static Point? Map(int x, int y, int cw, int ch, int gw, int gh) {
        if (cw <= 0 || ch <= 0 || gw <= 0 || gh <= 0) return null;
        double scale = Math.Min((double)cw / gw, (double)ch / gh), px = (x - (cw - gw * scale) / 2) / scale, py = (y - (ch - gh * scale) / 2) / scale;
        if (px < 0 || py < 0 || px >= gw || py >= gh) return null; return new Point((int)px, (int)py);
    }
    internal static Rectangle PictureBounds(Rectangle client, int gw, int gh, int dpi, int top) {
        int availableWidth = Math.Max(0, client.Width), availableHeight = Math.Max(0, client.Height - top);
        if (availableWidth == 0 || availableHeight == 0 || gw <= 0 || gh <= 0) return Rectangle.Empty;
        double dpiScale = Math.Max(1.0, dpi / 96.0);
        double limit = Math.Min(1.5, 1.25 + (dpiScale - 1.0) * 0.25);
        double scale = Math.Min(limit, Math.Min((double)availableWidth / gw, (double)availableHeight / gh));
        int width = Math.Max(1, (int)Math.Floor(gw * scale)), height = Math.Max(1, (int)Math.Floor(gh * scale));
        return new Rectangle(client.X + (availableWidth - width) / 2, client.Y + top + (availableHeight - height) / 2, width, height);
    }

    static string KeyName(Keys key, bool control, bool shift) {
        if (control) {
            if (shift && key == Keys.T) return "ctrl+shift+t";
            string value = key.ToString().ToLowerInvariant(); return "acvxzflrtw".IndexOf(value, StringComparison.Ordinal) >= 0 && value.Length == 1 ? "ctrl+" + value : null;
        }
        switch (key) {
            case Keys.Enter: return "Return"; case Keys.Back: return "BackSpace"; case Keys.Tab: return "Tab"; case Keys.Escape: return "Escape";
            case Keys.Delete: return "Delete"; case Keys.Left: return "Left"; case Keys.Right: return "Right"; case Keys.Up: return "Up"; case Keys.Down: return "Down";
            case Keys.Home: return "Home"; case Keys.End: return "End"; case Keys.PageUp: return "Page_Up"; case Keys.PageDown: return "Page_Down"; default: return null;
        }
    }
}
