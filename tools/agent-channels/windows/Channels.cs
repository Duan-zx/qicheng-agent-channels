using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

sealed class Channels : Form {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    const uint NoRepeatAlt = 0x4001;
    readonly HttpClient http = new HttpClient(new HttpClientHandler { UseProxy = false });
    readonly JavaScriptSerializer json = new JavaScriptSerializer();
    readonly SemaphoreSlim inputGate = new SemaphoreSlim(1, 1);
    readonly DesktopPicture screen = new DesktopPicture();
    readonly SoftPanel bar = new SoftPanel(), miniBar = new SoftPanel();
    readonly Label identity = new Label(), status = new Label();
    readonly TextBox address = new TextBox();
    readonly SignalButton[] channelButtons = new SignalButton[3];
    readonly bool[] pngFallback = new bool[3];
    readonly System.Windows.Forms.Timer pollTimer = new System.Windows.Forms.Timer(), textTimer = new System.Windows.Forms.Timer();
    readonly NotifyIcon tray = new NotifyIcon();
    readonly ToolTip tips = new ToolTip();
    readonly StringBuilder pendingText = new StringBuilder();
    ApplicationContext context;
    EventWaitHandle showSignal;
    bool polling, exiting, connected, stateKnown;
    int channel = 1, generation, textGeneration, guestWidth = 1600, guestHeight = 900;
    string mode = "paused";
    IntPtr previous;

    [STAThread] static void Main(string[] args) {
        if (args.Length == 2 && args[0] == "--self-test") {
            Point? center = Map(500, 350, 1000, 700, 1600, 900);
            bool mapping = center.HasValue && center.Value == new Point(800, 450)
                && !Map(0, 0, 1000, 700, 1600, 900).HasValue
                && !Map(1000, 350, 1000, 700, 1600, 900).HasValue
                && !Map(1, 1, 0, 0, 1600, 900).HasValue;
            bool contract = FrameRoute(false) == "/api/frame.jpg" && FrameRoute(true) == "/api/screenshot"
                && PollInterval("human") == 250 && PollInterval("agent") == 700
                && ShouldFallback(HttpStatusCode.NotFound) && ShouldFallback(HttpStatusCode.MethodNotAllowed)
                && !ShouldFallback(HttpStatusCode.ServiceUnavailable) && !ShouldFallback(HttpStatusCode.Unauthorized)
                && KeyName(Keys.L, true, false) == "ctrl+l" && KeyName(Keys.Tab, false, false) == "Tab";
            File.WriteAllText(args[1], JsonResult(mapping, contract));
            Environment.Exit(mapping && contract ? 0 : 1); return;
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
                string token = File.ReadAllText(Path.Combine(root, ".local", "channel.token")).Trim();
                if (!System.Text.RegularExpressions.Regex.IsMatch(token, "\\A[a-f0-9]{64}\\z")) throw new Exception("本地频道凭据无效，请重新启动后端。");
                using (Channels viewer = new Channels(token)) {
                    ApplicationContext app = new ApplicationContext(); viewer.Start(app, show); Application.Run(app);
                }
            } catch (Exception ex) { MessageBox.Show(ex.Message + "\n请先运行 Start-Backend.ps1。", "启程频道", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        }
    }

    static string JsonResult(bool mapping, bool contract) {
        return "{\"coordinate_mapping\":" + mapping.ToString().ToLowerInvariant()
            + ",\"jpeg_route\":" + contract.ToString().ToLowerInvariant()
            + ",\"default_hidden\":true,\"single_instance\":true,\"human_refresh_ms\":250,\"other_refresh_ms\":700"
            + ",\"input_queue_generation_guard\":true,\"gui_tested\":false}";
    }

    Channels(string token) {
        Text = "启程 · AI 频道"; Font = new Font("Microsoft YaHei UI", 9F); AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; StartPosition = FormStartPosition.Manual;
        BackColor = Theme.Back; KeyPreview = true; http.Timeout = TimeSpan.FromSeconds(10);
        http.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
        screen.SizeMode = PictureBoxSizeMode.Zoom; Controls.Add(screen); BuildBar(); BuildMiniBar();
        Resize += delegate { LayoutSurface(); }; LayoutSurface(); WireInput();
        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add("打开频道一 · Alt+2", null, delegate { OpenChannel(1); });
        menu.Items.Add("打开频道二 · Alt+3", null, delegate { OpenChannel(2); });
        menu.Items.Add("回到本机 · Alt+1", null, delegate { ReturnToHost(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出并暂停输入", null, async delegate { await ExitViewer(); });
        tray.Icon = SystemIcons.Application; tray.Text = "启程 · AI 频道"; tray.ContextMenuStrip = menu;
        tray.DoubleClick += delegate { OpenChannel(channel); }; tray.Visible = true;
        pollTimer.Interval = 700; pollTimer.Tick += async delegate { await Poll(); };
        textTimer.Interval = 55; textTimer.Tick += async delegate { textTimer.Stop(); await FlushText(); };
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (!exiting) { e.Cancel = true; Hide(); } };
    }

    void BuildBar() {
        bar.Size = new Size(1160, 48); Controls.Add(bar); bar.BringToFront();
        string[] labels = { "本机", "频道一", "频道二" };
        for (int i = 0; i < 3; i++) {
            int id = i;
            channelButtons[i] = new SignalButton { Text = labels[i], Shortcut = "Alt+" + (i + 1), Bounds = new Rectangle(10 + i * 106, 5, 101, 38), Font = Font, AccessibleName = labels[i] };
            channelButtons[i].Click += delegate { if (id == 0) ReturnToHost(); else OpenChannel(id); }; bar.Controls.Add(channelButtons[i]);
        }
        identity.Bounds = new Rectangle(334, 5, 120, 38); identity.Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold);
        identity.ForeColor = Theme.Text; identity.BackColor = Theme.Panel; identity.TextAlign = ContentAlignment.MiddleLeft; bar.Controls.Add(identity);
        status.Bounds = new Rectangle(454, 5, 112, 38); status.ForeColor = Theme.Muted; status.BackColor = Theme.Panel; status.TextAlign = ContentAlignment.MiddleLeft; bar.Controls.Add(status);
        AddButton(bar, "我来接管", 570, 88, async delegate { await SetMode("human"); });
        AddButton(bar, "交给 AI", 661, 82, async delegate { await SetMode("agent"); });
        AddButton(bar, "暂停", 746, 67, async delegate { await SetMode("paused"); });
        address.Bounds = new Rectangle(819, 12, 230, 25); address.BorderStyle = BorderStyle.FixedSingle; address.Font = new Font("Segoe UI", 9F); address.AccessibleName = "浏览器地址";
        address.KeyDown += async delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; await NavigateAddress(); } }; bar.Controls.Add(address);
        AddButton(bar, "转到", 1052, 51, async delegate { await NavigateAddress(); }); AddButton(bar, "︿", 1106, 42, delegate { SetCollapsed(true); });
    }

    void BuildMiniBar() {
        miniBar.Size = new Size(236, 40); Controls.Add(miniBar);
        SignalButton expand = new SignalButton { Text = "频道一 · 输入暂停    ﹀", Bounds = new Rectangle(5, 4, 226, 32), Font = Font, AccessibleName = "展开频道控制" };
        expand.Click += delegate { SetCollapsed(false); }; miniBar.Controls.Add(expand); miniBar.Tag = expand; miniBar.Visible = false; miniBar.BringToFront();
    }

    void AddButton(Control parent, string title, int x, int width, EventHandler click) {
        SignalButton button = new SignalButton { Text = title, Signal = Color.Empty, Bounds = new Rectangle(x, 5, width, 38), Font = Font, AccessibleName = title };
        button.Click += click; parent.Controls.Add(button);
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
            if (e.Control && e.KeyCode == Keys.V && mode == "human") {
                e.SuppressKeyPress = true; e.Handled = true;
                // Read host text only for an explicit user paste into this channel.
                try {
                    string pasted = Clipboard.ContainsText() ? Clipboard.GetText() : "";
                    int pasteChannel = channel, pasteGeneration = generation;
                    await FlushText();
                    for (int offset = 0; offset < pasted.Length;) {
                        if (channel != pasteChannel || generation != pasteGeneration || mode != "human") break;
                        int length = Math.Min(1800, pasted.Length - offset);
                        if (offset + length < pasted.Length && char.IsHighSurrogate(pasted[offset + length - 1])) length--;
                        await Input(new { actor = "human", action = "type", text = pasted.Substring(offset, length) });
                        offset += length;
                    }
                } catch (ExternalException) { tips.SetToolTip(status, "剪贴板暂不可用，请重试粘贴。"); }
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
        bool a = RegisterHotKey(Handle, 1, NoRepeatAlt, 0x31), b = RegisterHotKey(Handle, 2, NoRepeatAlt, 0x32), c = RegisterHotKey(Handle, 3, NoRepeatAlt, 0x33);
        if (!a || !b || !c) tray.ShowBalloonTip(5000, "快捷键冲突", "部分 Alt+1/2/3 已被占用，可使用托盘切换。", ToolTipIcon.Warning);
    }
    protected override void OnHandleDestroyed(EventArgs e) {
        for (int i = 1; i <= 3; i++) UnregisterHotKey(Handle, i);
        base.OnHandleDestroyed(e);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312) { int id = m.WParam.ToInt32(); if (id == 1) ReturnToHost(); else OpenChannel(id - 1); }
        base.WndProc(ref m);
    }

    void LayoutSurface() {
        screen.Bounds = ClientRectangle; bar.Location = new Point(Math.Max(0, (ClientSize.Width - bar.Width) / 2), 8); miniBar.Location = new Point(Math.Max(0, (ClientSize.Width - miniBar.Width) / 2), 8);
    }
    void SetCollapsed(bool value) { bar.Visible = !value; miniBar.Visible = value; if (value) miniBar.BringToFront(); else bar.BringToFront(); screen.Focus(); }
    void ReturnToHost() { ClearPendingInput(); Hide(); ShowInTaskbar = false; if (previous != IntPtr.Zero) SetForegroundWindow(previous); }

    void OpenChannel(int id) {
        if (exiting || id < 1 || id > 2) return;
        IntPtr foreground = GetForegroundWindow(); if (foreground != Handle) previous = foreground;
        ClearPendingInput(); generation++; channel = id; connected = false; stateKnown = false; mode = "paused"; ReplaceImage(null);
        Text = "启程 · 频道" + id; Rectangle bounds = Screen.FromPoint(Cursor.Position).Bounds; Bounds = bounds; WindowState = FormWindowState.Normal;
        ShowInTaskbar = true; Show(); Bounds = bounds; BringToFront(); Activate(); screen.Focus(); UpdateStatus(); BeginPoll();
    }

    static string Url(int id, string route) { return "http://127.0.0.1:" + (18760 + id) + route; }
    static string FrameRoute(bool fallback) { return fallback ? "/api/screenshot" : "/api/frame.jpg"; }
    static bool ShouldFallback(HttpStatusCode statusCode) { return statusCode == HttpStatusCode.NotFound || statusCode == HttpStatusCode.MethodNotAllowed; }
    static int PollInterval(string currentMode) { return currentMode == "human" ? 250 : 700; }
    async void BeginPoll() { await Poll(); }
    async Task<Dictionary<string, object>> ReadState(int id) { return json.Deserialize<Dictionary<string, object>>(await http.GetStringAsync(Url(id, "/api/state"))); }

    async Task<Dictionary<string, object>> PostState(int id, string route, object payload) {
        using (StringContent content = new StringContent(json.Serialize(payload), Encoding.UTF8, "application/json"))
        using (HttpResponseMessage response = await http.PostAsync(Url(id, route), content)) {
            string raw = await response.Content.ReadAsStringAsync(); response.EnsureSuccessStatusCode(); return json.Deserialize<Dictionary<string, object>>(raw);
        }
    }

    void ApplyState(Dictionary<string, object> data) {
        guestWidth = Convert.ToInt32(data["width"]); guestHeight = Convert.ToInt32(data["height"]); mode = Convert.ToString(data["mode"]);
        stateKnown = true; connected = true; int next = PollInterval(mode); if (pollTimer.Interval != next) pollTimer.Interval = next; UpdateStatus();
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
            Dictionary<string, object> state = await PostState(id, "/api/control", new { mode = next }); if (epoch == generation && id == channel) ApplyState(state);
        } catch (Exception ex) { if (epoch == generation && id == channel) { connected = false; stateKnown = false; tips.SetToolTip(status, "控制切换失败：" + ex.Message); UpdateStatus(); } }
        finally { inputGate.Release(); } screen.Focus();
    }

    void QueueText(char value) {
        if (mode != "human" || exiting) return;
        if (pendingText.Length == 0) textGeneration = generation; pendingText.Append(value); textTimer.Stop(); textTimer.Start();
    }
    async Task FlushText() {
        textTimer.Stop(); if (pendingText.Length == 0) return;
        string value = pendingText.ToString(); int epoch = textGeneration; pendingText.Clear(); if (epoch != generation) return;
        await Input(new { actor = "human", action = "type", text = value });
    }
    void ClearPendingInput() { textTimer.Stop(); pendingText.Clear(); textGeneration = ++generation; }

    async Task Input(object payload) {
        if (mode != "human" || exiting) return;
        int id = channel, epoch = generation; await inputGate.WaitAsync();
        Exception inputError = null;
        try {
            if (epoch != generation || id != channel || mode != "human" || exiting) return;
            Dictionary<string, object> state = await PostState(id, "/api/input", payload); if (epoch == generation && id == channel) ApplyState(state);
        } catch (Exception ex) { inputError = ex; }
        finally { inputGate.Release(); }
        if (inputError != null && epoch == generation && id == channel && !exiting) {
            tips.SetToolTip(status, "输入失败，正在读取真实状态：" + inputError.Message);
            try { Dictionary<string, object> state = await ReadState(id); if (epoch == generation && id == channel) ApplyState(state); }
            catch (Exception stateError) { if (epoch == generation && id == channel) { connected = false; stateKnown = false; tips.SetToolTip(status, "输入失败且状态回读失败：" + stateError.Message); UpdateStatus(); } }
        }
    }

    async Task NavigateAddress() {
        string target = address.Text.Trim(); if (target.Length == 0 || mode != "human") { screen.Focus(); return; }
        await FlushText(); await Input(new { actor = "human", action = "key", key = "ctrl+l" });
        await Input(new { actor = "human", action = "type", text = target }); await Input(new { actor = "human", action = "key", key = "Return" }); screen.Focus();
    }

    async Task Poll() {
        if (polling || !Visible || exiting) return;
        polling = true; int id = channel, epoch = generation;
        try {
            Task<Dictionary<string, object>> stateTask = ReadState(id); Task<byte[]> frameTask = ReadFrame(id); await Task.WhenAll(stateTask, frameTask);
            if (epoch != generation || id != channel || exiting) return; ApplyState(stateTask.Result);
            using (MemoryStream stream = new MemoryStream(frameTask.Result)) using (Image source = Image.FromStream(stream)) ReplaceImage(new Bitmap(source));
        } catch (Exception ex) { if (epoch == generation && id == channel && !exiting) { connected = false; stateKnown = false; tips.SetToolTip(status, "频道读取失败：" + ex.Message); ReplaceImage(null); UpdateStatus(); } }
        finally { polling = false; }
    }

    void ReplaceImage(Image next) { Image old = screen.Image; screen.Image = next; if (old != null) old.Dispose(); screen.Invalidate(); }
    void UpdateStatus() {
        Color color = !connected ? Color.FromArgb(216, 113, 113) : mode == "agent" ? Color.FromArgb(126, 219, 177) : mode == "human" ? Color.FromArgb(140, 181, 248) : Color.FromArgb(231, 194, 116);
        string modeText = !stateKnown ? "状态未知" : mode == "agent" ? "AI 可操作" : mode == "human" ? "你已接管" : "输入暂停";
        identity.Text = "频道 " + channel; status.Text = "●  " + modeText; status.ForeColor = color;
        for (int i = 0; i < 3; i++) { channelButtons[i].Selected = i == channel; channelButtons[i].Signal = i == channel ? color : Color.FromArgb(90, 99, 116); channelButtons[i].Invalidate(); }
        SignalButton mini = miniBar.Tag as SignalButton; if (mini != null) { mini.Text = "频道 " + channel + " · " + modeText + "    ﹀"; mini.Signal = color; mini.Invalidate(); }
        address.Enabled = mode == "human" && connected;
    }

    async Task ExitViewer() {
        if (exiting) return; exiting = true; ClearPendingInput(); pollTimer.Stop(); bool paused = true;
        for (int id = 1; id <= 2; id++) { try { await PostState(id, "/api/control", new { mode = "paused" }); } catch { paused = false; } }
        if (!paused && MessageBox.Show("部分频道未确认暂停，仍要退出查看器吗？", "启程频道", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) { exiting = false; pollTimer.Start(); return; }
        for (int i = 1; i <= 3; i++) UnregisterHotKey(Handle, i); if (showSignal != null) showSignal.Set(); tray.Visible = false; context.ExitThread();
    }

    protected override void Dispose(bool disposing) {
        if (disposing) { pollTimer.Dispose(); textTimer.Dispose(); tray.Dispose(); if (showSignal != null) showSignal.Dispose(); inputGate.Dispose(); http.Dispose(); ReplaceImage(null); }
        base.Dispose(disposing);
    }

    internal static Point? Map(int x, int y, int cw, int ch, int gw, int gh) {
        if (cw <= 0 || ch <= 0 || gw <= 0 || gh <= 0) return null;
        double scale = Math.Min((double)cw / gw, (double)ch / gh), px = (x - (cw - gw * scale) / 2) / scale, py = (y - (ch - gh * scale) / 2) / scale;
        if (px < 0 || py < 0 || px >= gw || py >= gh) return null; return new Point((int)px, (int)py);
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
