using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

static class Theme {
    public static readonly Color Back=Color.FromArgb(8,11,18), Panel=Color.FromArgb(15,20,31), Raised=Color.FromArgb(22,29,43), Input=Color.FromArgb(10,15,25), Edge=Color.FromArgb(52,65,87);
    public static readonly Color Text=Color.FromArgb(239,243,250), Muted=Color.FromArgb(151,164,184), Human=Color.FromArgb(117,178,255), Agent=Color.FromArgb(166,184,255), Pause=Color.FromArgb(241,188,111), Offline=Color.FromArgb(225,126,126);
    public static GraphicsPath Rounded(Rectangle r,int radius) {
        GraphicsPath p=new GraphicsPath(); int d=Math.Max(2,radius*2);
        p.AddArc(r.X,r.Y,d,d,180,90);p.AddArc(r.Right-d,r.Y,d,d,270,90);p.AddArc(r.Right-d,r.Bottom-d,d,d,0,90);p.AddArc(r.X,r.Bottom-d,d,d,90,90);p.CloseFigure();return p;
    }
}
sealed class SoftPanel : Panel {
    public Color Fill=Theme.Panel;
    public Color Edge=Theme.Edge;
    public int Radius=-1;
    public SoftPanel(){DoubleBuffered=true; BackColor=Theme.Back;}
    protected override void OnPaint(PaintEventArgs e){
        if(Width<2||Height<2){base.OnPaint(e);return;}
        e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
        int radius=Radius>0?Radius:Math.Max(8,Height/2);
        using(GraphicsPath p=Theme.Rounded(new Rectangle(0,0,Width-1,Height-1),radius))
        using(SolidBrush b=new SolidBrush(Fill)) using(Pen edge=new Pen(Edge)){e.Graphics.FillPath(b,p);e.Graphics.DrawPath(edge,p);}
    }
}
enum ButtonTone { Quiet, Human, HumanActive, Agent, AgentActive, Pause, PauseActive, Icon }
sealed class SignalButton : Button {
    public Color Signal=Color.FromArgb(90,99,116);
    public bool Selected;
    public string Shortcut="";
    public ButtonTone Tone=ButtonTone.Quiet;
    bool hover;
    public SignalButton(){ SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true); FlatStyle=FlatStyle.Flat;FlatAppearance.BorderSize=0;Cursor=Cursors.Hand;BackColor=Theme.Panel;ForeColor=Theme.Text;TabStop=true; }
    protected override void OnMouseEnter(EventArgs e){hover=true;Invalidate();base.OnMouseEnter(e);}
    protected override void OnMouseLeave(EventArgs e){hover=false;Invalidate();base.OnMouseLeave(e);}
    void Palette(out Color fill,out Color edge,out Color text){
        fill=Color.Empty;edge=Color.Empty;text=Theme.Text;
        switch(Tone){
            case ButtonTone.Human: fill=Color.FromArgb(10,Theme.Human);edge=Color.FromArgb(96,Theme.Human);text=Color.FromArgb(226,237,255);break;
            case ButtonTone.HumanActive: fill=Color.FromArgb(56,Theme.Human);edge=Color.FromArgb(180,Theme.Human);break;
            case ButtonTone.Agent: fill=Color.FromArgb(10,Theme.Agent);edge=Color.FromArgb(92,Theme.Agent);text=Color.FromArgb(231,235,255);break;
            case ButtonTone.AgentActive: fill=Color.FromArgb(50,Theme.Agent);edge=Color.FromArgb(174,Theme.Agent);break;
            case ButtonTone.Pause: fill=Color.FromArgb(9,Theme.Pause);edge=Color.FromArgb(82,Theme.Pause);text=Color.FromArgb(252,235,207);break;
            case ButtonTone.PauseActive: fill=Color.FromArgb(48,Theme.Pause);edge=Color.FromArgb(172,Theme.Pause);text=Color.FromArgb(255,244,222);break;
            case ButtonTone.Icon: fill=Color.FromArgb(21,31,47);edge=Color.FromArgb(68,84,112);break;
            default: if(Selected||hover||Focused){fill=Color.FromArgb(33,42,59);edge=Color.FromArgb(77,94,122);}break;
        }
        if(Tone!=ButtonTone.Quiet&&hover&&!Focused){edge=Color.FromArgb(210,edge);}
    }
    protected override void OnPaint(PaintEventArgs e){
        Graphics g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;g.Clear(BackColor);if(Width<2||Height<2)return;
        Color fill,edge,text;Palette(out fill,out edge,out text);
        if(!Enabled){fill=Color.FromArgb(13,Theme.Raised);edge=Color.FromArgb(46,Theme.Edge);text=Theme.Muted;}
        if(fill!=Color.Empty){using(GraphicsPath p=Theme.Rounded(new Rectangle(0,1,Width-1,Height-3),Math.Max(12,(Height-3)/2))){using(SolidBrush b=new SolidBrush(fill))g.FillPath(b,p);if(edge!=Color.Empty)using(Pen pen=new Pen(edge))g.DrawPath(pen,p);}}
        if(Signal!=Color.Empty){using(SolidBrush halo=new SolidBrush(Color.FromArgb(26,Signal)))g.FillEllipse(halo,9,Height/2-8,16,16);using(SolidBrush dot=new SolidBrush(Signal))g.FillEllipse(dot,13,Height/2-4,8,8);}
        int start=Signal==Color.Empty?12:29;int shortcutWidth=Shortcut.Length>0?42:5;
        TextRenderer.DrawText(g,Text,Font,new Rectangle(start,0,Math.Max(0,Width-start-shortcutWidth),Height),text,TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPadding);
        if(Shortcut.Length>0)using(Font f=new Font("Segoe UI",8))TextRenderer.DrawText(g,Shortcut,f,new Rectangle(Width-43,0,39,Height),Theme.Muted,TextFormatFlags.Right|TextFormatFlags.VerticalCenter|TextFormatFlags.NoPadding);
        if(Focused)using(GraphicsPath p=Theme.Rounded(new Rectangle(2,3,Math.Max(0,Width-5),Math.Max(0,Height-7)),Math.Max(10,(Height-7)/2)))using(Pen focus=new Pen(Color.FromArgb(185,Theme.Text)))g.DrawPath(focus,p);
    }
}
sealed class DesktopPicture : PictureBox {
    public string Headline="你的频道已经就绪。";
    public string Detail="按 Alt+2 或 Alt+3 打开；需要时接管，完成后交给 AI。";
    public DesktopPicture(){SetStyle(ControlStyles.Selectable|ControlStyles.OptimizedDoubleBuffer,true);TabStop=true;BackColor=Theme.Back;}
    protected override bool IsInputKey(Keys keyData){return true;}
    protected override void OnPaint(PaintEventArgs e){
        if(Image!=null){base.OnPaint(e);return;}
        Graphics g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;g.Clear(Theme.Back);
        int cx=(int)(Width*.77),cy=(int)(Height*.47),rad=(int)(Math.Min(Width,Height)*.27);
        if(rad>0)using(GraphicsPath glow=new GraphicsPath()){
            glow.AddEllipse(cx-rad,cy-rad,rad*2,rad*2);
            using(PathGradientBrush b=new PathGradientBrush(glow)){b.CenterColor=Color.FromArgb(48,67,89);b.SurroundColors=new[]{Theme.Back};g.FillPath(b,glow);}
            for(int i=0;i<3;i++)using(Pen p=new Pen(Color.FromArgb(33+i*8,126,163,197),1)){int r=rad*(7+i*2)/10;g.DrawEllipse(p,cx-r,cy-r/2,r*2,r);}
            using(SolidBrush b=new SolidBrush(Color.FromArgb(158,222,198)))g.FillEllipse(b,cx+rad/2-4,cy-rad/3-4,8,8);
        }
        int left=Math.Max(36,(int)(Width*.13)), top=(int)(Height*.33);
        using(Font eyebrow=new Font("Segoe UI",10,FontStyle.Regular))
        using(Font heading=new Font("Microsoft YaHei UI",Width>1000?30:23,FontStyle.Regular))
        using(Font detail=new Font("Microsoft YaHei UI",12,FontStyle.Regular)){
            TextRenderer.DrawText(g,"QICHENG  /  AI WORKSPACE",eyebrow,new Point(left,top-48),Color.FromArgb(117,157,171));
            TextRenderer.DrawText(g,Headline,heading,new Rectangle(left,top,Width-left-35,75),Theme.Text,TextFormatFlags.Left|TextFormatFlags.NoPrefix);
            TextRenderer.DrawText(g,Detail,detail,new Point(left,top+88),Theme.Muted);
            TextRenderer.DrawText(g,"ALT + 1   回到本机       ALT + 2 / 3   切换频道",eyebrow,new Point(left,top+151),Color.FromArgb(102,113,131));
        }
    }
}
