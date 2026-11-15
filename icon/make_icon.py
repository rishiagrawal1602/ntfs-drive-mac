from PIL import Image, ImageDraw, ImageFont, ImageFilter
S=1024
img=Image.new("RGBA",(S,S),(0,0,0,0))
# rounded tile with vertical gradient (deep navy -> azure)
grad=Image.new("RGBA",(S,S))
gd=ImageDraw.Draw(grad)
for y in range(S):
    t=y/S
    c=(int(10+(0-10)*t),int(40+(120-40)*t),int(110+(215-110)*t),255)
    gd.line([(0,y),(S,y)],fill=c)
mask=Image.new("L",(S,S),0)
ImageDraw.Draw(mask).rounded_rectangle([40,40,S-40,S-40],radius=200,fill=255)
img.paste(grad,(0,0),mask)
d=ImageDraw.Draw(img)
# four-pane window glyph in perspective (original design)
def quad(pts,fill): d.polygon(pts,fill=fill)
L,R,T,B,M=250,774,170,650,512
gap=18
# left side taller perspective: left edge x=250 spans T..B, right edge x=774 spans T-40..B+40
def lerp(a,b,t): return a+(b-a)*t
def edge_y(x,base,delta):
    t=(x-L)/(R-L); return base+delta*t
xm=M
panes=[((L,xm-gap/2),"top"),((xm+gap/2,R),"top"),((L,xm-gap/2),"bot"),((xm+gap/2,R),"bot")]
colors=[(255,255,255,240),(220,240,255,240),(220,240,255,240),(255,255,255,240)]
for ((x0,x1),pos),col in zip(panes,colors):
    if pos=="top":
        y0a,y0b=edge_y(x0,T,-50),edge_y(x1,T,-50)
        y1a,y1b=edge_y(x0,(T+B)/2-gap/2,0),edge_y(x1,(T+B)/2-gap/2,0)
    else:
        y0a,y0b=edge_y(x0,(T+B)/2+gap/2,0),edge_y(x1,(T+B)/2+gap/2,0)
        y1a,y1b=edge_y(x0,B,50),edge_y(x1,B,50)
    quad([(x0,y0a),(x1,y0b),(x1,y1b),(x0,y1a)],col)
# NTFS label
font=None
for f in ["/System/Library/Fonts/SFNSRounded.ttf","/System/Library/Fonts/SFNS.ttf","/System/Library/Fonts/Helvetica.ttc","/Library/Fonts/Arial Bold.ttf"]:
    try: font=ImageFont.truetype(f,190); break
    except Exception: pass
txt="NTFS"
bb=d.textbbox((0,0),txt,font=font)
w=bb[2]-bb[0]
d.text(((S-w)/2-bb[0],735),txt,font=font,fill=(255,255,255,255))
img.save("icon_1024.png")
