using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

static class Theme {
    public static readonly Color Back=Color.FromArgb(12,15,21), Panel=Color.FromArgb(24,28,36), Text=Color.FromArgb(236,239,244), Muted=Color.FromArgb(133,145,163);
    public static GraphicsPath Rounded(Rectangle r,int radius) {
        GraphicsPath p=new GraphicsPath(); int d=radius*2;
        p.AddArc(r.X,r.Y,d,d,180,90);p.AddArc(r.Right-d,r.Y,d,d,270,90);p.AddArc(r.Right-d,r.Bottom-d,d,d,0,90);p.AddArc(r.X,r.Bottom-d,d,d,90,90);p.CloseFigure();return p;
    }
}
sealed class SoftPanel : Panel {
    public SoftPanel(){DoubleBuffered=true; BackColor=Theme.Back;}
    protected override void OnPaint(PaintEventArgs e){
        e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
        using(GraphicsPath p=Theme.Rounded(new Rectangle(0,0,Width-1,Height-1),Height/2))
        using(SolidBrush b=new SolidBrush(Theme.Panel)) using(Pen edge=new Pen(Color.FromArgb(46,53,65))){e.Graphics.FillPath(b,p);e.Graphics.DrawPath(edge,p);}
    }
}
sealed class SignalButton : Button {
    public Color Signal=Color.FromArgb(90,99,116);
    public bool Selected;
    public string Shortcut="";
    bool hover;
    public SignalButton(){ SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true); FlatStyle=FlatStyle.Flat;FlatAppearance.BorderSize=0;Cursor=Cursors.Hand;BackColor=Theme.Panel;ForeColor=Theme.Text;TabStop=true; }
    protected override void OnMouseEnter(EventArgs e){hover=true;Invalidate();base.OnMouseEnter(e);}
    protected override void OnMouseLeave(EventArgs e){hover=false;Invalidate();base.OnMouseLeave(e);}
    protected override void OnPaint(PaintEventArgs e){
        Graphics g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;g.Clear(BackColor);
        if(Selected||hover||Focused)using(GraphicsPath p=Theme.Rounded(new Rectangle(0,1,Width-1,Height-3),16))using(SolidBrush b=new SolidBrush(Selected?Color.FromArgb(45,52,66):Color.FromArgb(33,39,49)))g.FillPath(b,p);
        if(Signal!=Color.Empty){using(SolidBrush halo=new SolidBrush(Color.FromArgb(24,Signal)))g.FillEllipse(halo,9,Height/2-8,16,16);using(SolidBrush dot=new SolidBrush(Signal))g.FillEllipse(dot,13,Height/2-4,8,8);}
        int start=Signal==Color.Empty?12:29;
        TextRenderer.DrawText(g,Text,Font,new Rectangle(start,0,Width-start,Height),ForeColor,TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);
        if(Shortcut.Length>0)using(Font f=new Font("Segoe UI",8))TextRenderer.DrawText(g,Shortcut,f,new Rectangle(Width-39,0,35,Height),Theme.Muted,TextFormatFlags.Right|TextFormatFlags.VerticalCenter);
    }
}
sealed class DesktopPicture : PictureBox {
    public string Headline="给 AI 一张独立的桌面。";
    public string Detail="你继续工作，它在自己的频道里行动。";
    public DesktopPicture(){SetStyle(ControlStyles.Selectable|ControlStyles.OptimizedDoubleBuffer,true);TabStop=true;BackColor=Theme.Back;}
    protected override bool IsInputKey(Keys keyData){return true;}
    protected override void OnPaint(PaintEventArgs e){
        if(Image!=null){base.OnPaint(e);return;}
        Graphics g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;g.Clear(Theme.Back);
        float sx=Width/1440f, sy=Height/900f;
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
            TextRenderer.DrawText(g,"QICHENG  /  AGENT CHANNELS",eyebrow,new Point(left,top-48),Color.FromArgb(117,157,171));
            TextRenderer.DrawText(g,Headline,heading,new Rectangle(left,top,Width-left-35,75),Theme.Text,TextFormatFlags.Left|TextFormatFlags.NoPrefix);
            TextRenderer.DrawText(g,Detail,detail,new Point(left,top+88),Theme.Muted);
            TextRenderer.DrawText(g,"ALT + 1   回到本机       ALT + 2 / 3   切换频道",eyebrow,new Point(left,top+151),Color.FromArgb(102,113,131));
        }
    }
}
