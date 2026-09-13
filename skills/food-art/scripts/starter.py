#!/usr/bin/env python3
"""Retained original drawing construction. Only seeds missing starter sources."""
from library import ART, dump
import math

def p(d,fill='none',width=1.1,opacity=1):return {'d':d,'fill':fill,'width':width,'opacity':opacity}
def oval(x,y,rx,ry,fill='cream',width=1.1):
    return p(f'M{x-rx} {y} C{x-rx-1} {y-ry*.58} {x-rx*.52} {y-ry} {x} {y-ry} C{x+rx*.64} {y-ry+1} {x+rx} {y-ry*.45} {x+rx} {y} C{x+rx-1} {y+ry*.7} {x+rx*.47} {y+ry} {x} {y+ry} C{x-rx*.6} {y+ry-1} {x-rx} {y+ry*.48} {x-rx} {y} Z',fill,width)
def plate():return [oval(128,157,88,36,'cream'),oval(128,150,76,28,'paper',.8),p('M70 180 Q124 198 181 179',width=.6,opacity=.6)]
def bowl():return [p('M49 134 C53 169 73 196 125 200 C174 200 198 174 207 137 Z','sage'),p('M74 177 Q118 201 173 181',width=.6,opacity=.6),oval(128,133,79,32,'cream'),oval(128,133,69,24,'paper',.7)]
def leaf(x,y,s=1):return [p(f'M{x} {y} C{x-21*s} {y-20*s} {x-27*s} {y-43*s} {x-14*s} {y-46*s} C{x+9*s} {y-49*s} {x+16*s} {y-13*s} {x} {y} Z','sage',.9),p(f'M{x} {y} Q{x-1*s} {y-23*s} {x-14*s} {y-41*s}',width=.6)]
def grain(x,y):return p(f'M{x} {y} q3 -5 6 -2 q1 3 -4 5 q-4 0 -2 -3 Z','paper',.55)
def seeds(x,y,n):return [oval(x+(i%4)*8,y+(i//4)*7,2.5,1.7,'ochre',.4) for i in range(n)]
items=[]
def add(id,name,aliases,cat,layers,desc,kind='food'):
    items.append({'id':id,'name':name,'aliases':aliases,'category':cat,'kind':kind,'description':desc,'layers':layers})

add('jasmine-rice','Jasmine rice',['steamed rice','white rice','ข้าวสวย'],'grains',bowl()+[p('M64 132 Q66 112 83 110 Q83 92 104 97 Q120 81 137 94 Q157 89 172 108 Q192 111 192 134 Q139 158 64 132 Z','paper')]+[grain(77+(i%8)*13,110+(i//8)*10+(i%3)*2) for i in range(24)],'A low sage bowl carrying a pale mound of steamed rice, with sparse individual grains.')
noodles=bowl()+[p('M65 128 Q98 101 147 112 Q175 111 192 136 Q135 156 65 128 Z','gold')]
for i in range(8):
    y=117+i*3.6
    noodles.append(p(f'M{75+i*2} {y} C98 {y-16} 116 {y+20} 137 {y-4} S174 {y+10} 184 {y+1}',width=.85))
noodles+=leaf(103,122,.36)+leaf(168,141,.4)+[p('M83 101 L177 75 M91 106 L182 81',width=2)]
add('stir-fried-noodles','Stir-fried noodles',['noodles','ผัดหมี่'],'grains',noodles,'Ochre looping noodles in a shallow sage bowl, two small leaves and angled chopsticks.')
soup=bowl()+[oval(128,134,66,22,'gold',.6),oval(98,129,13,6,'orange',.6),oval(149,139,12,5,'orange',.6)]
soup+=leaf(127,135,.42)+leaf(168,137,.38)+[p('M81 139 q10 -10 18 2 M144 121 q8 -6 13 3',width=.7)]
add('vegetable-soup','Clear vegetable soup',['clear soup','vegetable broth','แกงจืด'],'soup',soup,'Clear golden broth with carrot ovals and sage leaves in a rounded bowl.')
chicken=plate()+[p('M79 139 C77 128 92 124 98 115 C102 105 124 101 139 105 C153 108 174 121 170 137 C166 150 146 164 125 164 C104 165 86 153 79 139 Z','peach')]
for d in ['M96 128 Q111 129 125 145 L124 148 Q107 133 95 131 Z','M108 116 Q129 126 141 146 L139 149 Q128 133 107 119 Z','M124 110 Q145 121 153 136 L151 140 Q142 122 123 113 Z','M140 112 Q158 121 162 129 L160 132 Q152 120 139 115 Z']:
    chicken.append(p(d,'ochre',.5,.9))
chicken += [p('M88 143 Q104 152 119 154 M136 155 l10 -5',width=.6,opacity=.6)]
chicken+=leaf(181,157,.63)+[p('M65 155 Q65 137 80 131 L87 156 Z','gold')]
add('grilled-chicken','Grilled chicken',['chicken breast','ไก่ย่าง'],'protein',chicken,'A hand-shaped grilled chicken breast with fine sear marks, a leaf and a lemon wedge on an oval plate.')
salmon=plate()+[p('M76 128 L132 99 Q143 96 153 104 L183 137 Q189 146 175 155 L111 172 Q97 171 91 159 Z','orange'),p('M92 157 Q137 155 180 138 L181 149 Q142 172 111 175 L95 167 Z','brown',.7)]
for i in range(5):salmon.append(p(f'M{92+i*12} {126-i*4} q20 6 27 23',width=1,opacity=.8))
salmon+=leaf(77,158,.55)
add('salmon','Salmon fillet',['grilled salmon','ปลาแซลมอน'],'protein',salmon,'A terracotta salmon fillet with curved flesh lines and a narrow skin edge on a cream plate.')
add('fried-egg','Fried egg',['sunny-side-up egg','ไข่ดาว'],'protein',plate()+[p('M74 135 C63 119 83 103 102 113 C112 92 139 102 148 111 C172 104 184 122 175 134 C195 150 167 165 150 156 C126 177 108 158 95 162 C69 166 62 146 74 135 Z','paper'),oval(127,132,24,20,'gold'),p('M113 125 q5 -9 15 -7',width=.65,opacity=.5)],'An irregular pale fried egg and ochre yolk resting on a small oval plate.')
add('toast','Toast',['bread','wholegrain toast','ขนมปังปิ้ง'],'grains',plate()+[p('M81 167 L74 117 Q57 96 80 85 Q115 65 152 83 Q177 93 161 114 L177 159 Z','ochre'),p('M89 157 L84 113 Q72 99 89 92 Q119 78 147 94 Q159 99 151 113 L164 151 Z','peach')]+seeds(101,109,12)+[p('M110 141 l19 -4 l-2 -13 l-20 4 Z','gold',.6)],'One asymmetrical slice of toasted bread, with scattered crumb marks and a small butter pat.')
broccoli=plate()+[p('M111 175 Q119 153 109 137 L93 123 L102 114 L126 139 L144 111 L155 119 L135 149 L137 172 Z','leaf'),p('M121 165 Q128 147 146 124 M125 148 L106 127',width=.8)]
for x,y,rx,ry in [(84,119,19,14),(104,101,24,21),(133,100,23,21),(156,119,24,17),(118,121,28,17)]:
    d=f'M{x-rx} {y}'
    for j in range(1,19):
        a=math.pi+j*math.tau/18;r=1 if j%2 else .85
        d+=f' L{x+math.cos(a)*rx*r:.2f} {y+math.sin(a)*ry*r:.2f}'
    broccoli.append(p(d+' Z','forest',.9))
    for dx,dy in [(-7,-4),(2,-8),(8,1),(-3,5)]:broccoli.append(p(f'M{x+dx} {y+dy} q-2 -5 3 -4 q4 -1 4 3',width=.55,opacity=.7))
broccoli+=[p('M95 114 q5 -6 11 -1 M126 95 q5 -9 11 -3 M140 120 q4 -7 10 -2',width=.6)]
add('broccoli','Broccoli',['steamed broccoli','บรอกโคลี'],'produce',broccoli,'An upright broccoli floret, forked pale stem and rounded sage crown, on a low plate.')
mango=[p('M70 155 C45 135 61 92 88 77 C121 62 145 77 143 110 C142 142 99 175 70 155 Z','gold'),p('M89 79 q-6 -9 1 -15',width=1.6)]+leaf(113,87,.6)+[p('M118 158 Q143 103 192 107 Q210 140 178 172 Q145 190 118 158 Z','orange'),p('M124 155 Q153 119 190 115 Q198 144 175 165 Q145 177 124 155 Z','gold',.7)]
for d in ['M137 142 L152 171','M151 129 L169 167','M168 119 L185 149','M132 154 L192 135','M143 165 L193 146']:mango.append(p(d,width=.65))
add('mango','Mango',['ripe mango','มะม่วง'],'produce',mango,'A whole ochre mango with a small leaf beside a cross-cut golden cheek; no serving-size claim.')
add('banana','Banana',['กล้วย'],'produce',[p('M58 102 Q67 155 121 157 Q169 155 190 102 L199 96 Q204 147 161 178 Q104 207 62 153 Q50 132 50 112 Z','gold'),p('M57 111 Q88 195 177 155 M64 115 Q95 171 172 145',width=.8),p('M50 112 L46 101 L55 94 L62 103 Z','brown'),p('M188 104 l4 -14 l8 2 l-1 12 Z','brown')],'A curved golden banana with a slender brown stem and two fine longitudinal contour lines.')
orange=[oval(105,132,47,48,'orange'),p('M98 87 q4 -9 10 -10',width=1.4)]+leaf(123,91,.68)+[p('M132 142 Q169 110 207 135 Q196 176 157 186 Z','orange'),p('M140 144 Q170 120 199 139 Q189 170 159 178 Z','peach',.7)]
for d in ['M168 139 L161 175','M170 140 L184 161','M169 139 L192 143']:orange.append(p(d,width=.7))
add('orange','Orange',['citrus','ส้ม'],'produce',orange,'A round terracotta orange with a botanical leaf beside an open segmented wedge.')
coffee=[oval(123,178,76,21,'cream'),p('M170 115 C211 106 214 151 176 156 L174 145 C198 145 199 122 174 126 Z','cream'),p('M74 111 Q80 174 122 178 Q164 177 178 111 Z','cream'),oval(126,111,52,19,'paper'),oval(126,112,44,13,'brown',.7),p('M85 134 Q90 159 104 165',width=.7),p('M113 86 C99 70 123 63 112 47 M142 85 C130 71 150 65 141 52',width=.8,opacity=.7)]
add('coffee','Coffee',['black coffee','กาแฟ'],'drinks',coffee,'A cream ceramic coffee cup, curved handle, saucer and two delicate steam strokes.')
add('fallback-grains','Grains · fallback',['grain category'],'grains',bowl()+[p('M66 132 Q97 96 129 109 Q161 98 190 132 Q135 159 66 132 Z','cream')]+[grain(82+(i%7)*13,123+(i//7)*10) for i in range(14)],'Generic pale grain bowl; category fallback, not a specific dish.','fallback')
add('fallback-protein','Protein · fallback',['protein category'],'protein',plate()+[p('M81 143 Q87 112 109 118 L157 116 Q174 128 173 152 L109 168 Z','peach'),p('M94 135 L152 130 M102 148 L159 143',width=.8)],'Generic protein portion on a plate; intentionally nonspecific, not dietary or ingredient evidence.','fallback')
add('fallback-produce','Produce · fallback',['produce category'],'produce',[oval(103,148,38,33,'gold'),p('M101 116 q0 -10 6 -16',width=1.4)]+leaf(157,181,1.4)+leaf(104,117,.5),'Generic fruit and leafy produce study; category fallback rather than an exact ingredient.','fallback')
add('fallback-drinks','Drink · fallback',['beverage category'],'drinks',[p('M82 88 L93 179 Q128 197 163 179 L177 90 Z','cream'),oval(130,88,48,13,'paper'),p('M91 126 Q129 140 170 126 L161 176 Q129 190 96 176 Z','peach',.8),p('M102 101 L106 119 M105 139 L109 168',width=.7)],'A plain drinking glass with a restrained pale wash; contents intentionally unspecified.','fallback')

if __name__=='__main__':
    for item in items:
        dest=ART/'sources'/f'{item["id"]}.json'
        if not dest.exists():dump(dest,item)
    print('Starter sources:',len(items),'— existing sources preserved')
