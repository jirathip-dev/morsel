"""Deterministic original SVG studies + two HTML shells. Python stdlib only."""
from pathlib import Path
import json
ROOT = Path(__file__).resolve().parent
foods = [
 dict(id='focaccia',name='Focaccia bread',quantity=100,unit='g',kcal=300,p=8,c=46,f=9,source='Photo estimate',confidence=.82,notes='Illustrative estimate; oil and bread thickness are uncertain.',photo=True),
 dict(id='mortadella',name='Mortadella',quantity=40,unit='g',kcal=125,p=6,c=1,f=11,source='Photo estimate',confidence=.78,notes='Illustrative portion estimate; not a weighed serving.',photo=True),
 dict(id='stracciatella',name='Stracciatella cheese',quantity=50,unit='g',kcal=130,p=5,c=2,f=11,source='Photo estimate',confidence=.62,notes='Soft cheese quantity is uncertain in this fictional fixture.',photo=True),
 dict(id='vegetables',name='Grilled vegetables',quantity=80,unit='g',kcal=70,p=2,c=8,f=3,source='Manual',confidence=.9,notes=None,photo=True),
 dict(id='unknown',name='Unidentified side',quantity=1,unit='serving',kcal=90,p=2,c=10,f=5,source='Photo estimate',confidence=.35,notes='Food identity is unknown. Neutral artwork makes no ingredient claim.',photo=False)
]
fixture = dict(disclaimer='Fictional design fixture. All nutrition and goals are illustrative, not dietary advice or owner data.',goal=2000,macroGoals=[100,250,65],movement=None,foods=foods)
(ROOT/'fixture.json').write_text(json.dumps(fixture,indent=2)+'\n')
(ROOT/'fixture.js').write_text('window.FIXTURE = '+json.dumps(fixture)+';\n')
# Authored paths: no traced source or external art; no procedural noise filters.
shapes={
'focaccia': '''<path fill="#A5750B" d="M31 114 L169 94 221 131 215 172 80 197 33 165Z"/><path fill="#FBE1C9" d="M33 133 L80 161 215 137 213 171 82 193 34 164Z"/><path fill="#D6A62C" d="M29 111 Q44 94 64 96 L167 78 221 113 219 140 80 166 29 139Z"/><path fill="#FBE1C9" opacity=".48" d="M35 111 L165 84 207 111 78 148Z"/><g fill="#A5750B"><ellipse cx="65" cy="116" rx="8" ry="5"/><ellipse cx="104" cy="110" rx="7" ry="4"/><ellipse cx="149" cy="102" rx="7" ry="5"/><ellipse cx="181" cy="117" rx="8" ry="4"/><ellipse cx="132" cy="130" rx="8" ry="5"/><ellipse cx="86" cy="140" rx="6" ry="4"/></g><g stroke="#5E7E57" stroke-width="3" stroke-linecap="round"><path d="M59 104 l9 -8 m-6 5 9 1 M113 123 l12 -7 m-7 4 1 -8 M170 137 l10 -8"/></g><g fill="#8B7355"><ellipse cx="61" cy="165" rx="4" ry="3"/><ellipse cx="91" cy="174" rx="6" ry="4"/><ellipse cx="117" cy="170" rx="3" ry="5"/><ellipse cx="150" cy="165" rx="5" ry="3"/><ellipse cx="182" cy="157" rx="4" ry="4"/></g>''',
'mortadella': '''<path fill="#B94738" opacity=".65" d="M38 129 C30 75 106 60 155 91 C195 68 237 125 210 164 C182 202 125 188 107 174 C67 192 39 171 38 129Z"/><path fill="#FBE1C9" d="M41 119 C44 72 108 72 145 97 C169 114 164 154 134 167 C96 184 41 163 41 119Z"/><path fill="#B94738" opacity=".34" d="M47 120 C50 83 107 78 141 101 C168 121 151 151 128 161 C93 177 48 155 47 120Z"/><path fill="#FBE1C9" d="M100 124 C127 88 192 95 210 133 C227 168 185 189 151 177 C129 169 126 139 100 124Z"/><path fill="#B94738" opacity=".42" d="M106 124 C140 105 191 105 207 135 C220 162 188 183 158 173 C133 163 134 139 106 124Z"/><g fill="#FFF7E8"><path d="M65 114 l8 -4 5 9 -10 4Z M106 93 l10 3 -3 9 -9 -2Z M85 145 l11 -3 3 10 -8 3Z M151 126 l10 -5 5 8 -9 7Z M181 153 l9 -2 3 10 -11 3Z M144 152 l7 3 -3 8 -6 -4Z"/></g><path d="M105 126 Q126 130 135 153" fill="none" stroke="var(--line)" stroke-width="2"/>''',
'stracciatella': '''<path fill="#8B7355" opacity=".14" d="M36 166 Q98 121 215 156 Q210 196 114 201 Q50 197 36 166Z"/><path fill="#F2E9D9" d="M40 162 Q38 135 69 133 Q57 113 94 107 Q88 87 120 92 Q144 69 166 105 Q197 95 193 125 Q223 139 212 164 Q184 193 128 188 Q72 193 40 162Z"/><path fill="#FFFCF5" d="M60 153 Q82 121 101 142 Q100 106 127 109 Q149 89 159 127 Q190 117 195 143 Q173 178 132 169 Q89 180 60 153Z"/><g fill="none" stroke="var(--line)" stroke-linecap="round"><path stroke-width="2.5" d="M63 149 Q79 159 98 145 M96 124 Q110 141 108 162 M123 109 Q116 145 142 161 M157 119 Q147 140 167 155 M186 140 Q178 157 185 166"/><path stroke-width="1.4" d="M65 169 Q88 179 108 171 M123 179 Q152 185 170 172"/></g>''',
'vegetables': '''<path fill="#B94738" d="M36 152 Q39 104 99 94 L108 112 Q63 124 67 155 L92 174 77 188 Q45 180 36 152Z"/><path fill="#E66A2C" d="M108 94 Q134 72 165 90 L153 108 Q130 96 118 120 L142 140 129 156 Q90 133 108 94Z"/><path fill="#5E7E57" d="M93 151 Q126 109 198 116 L215 140 Q170 173 110 183Z"/><path fill="#E1E9D7" d="M106 150 Q148 122 192 123 L202 137 Q152 164 116 170Z"/><path fill="#655A4B" d="M114 184 Q153 149 207 157 L216 177 Q187 201 138 204Z"/><path fill="#F2E9D9" d="M130 181 Q163 161 202 165 L205 177 Q174 194 140 195Z"/><g fill="none" stroke="#655A4B" stroke-width="4" stroke-linecap="round"><path d="M122 143 l11 15 M147 134 l11 14 M172 128 l9 12 M54 129 l14 8 M64 111 l11 6 M144 178 l6 11 M168 171 l6 12"/></g>''',
'unknown': '''<path fill="#8B7355" opacity=".16" d="M34 170 Q115 201 222 162 L209 184 Q119 217 48 189Z"/><path fill="#F2E9D9" d="M36 127 Q109 106 218 127 L199 176 Q126 198 54 175Z"/><ellipse fill="#FFFCF5" stroke="var(--line)" stroke-width="2" cx="127" cy="127" rx="91" ry="27"/><ellipse fill="#E3D2BA" cx="127" cy="128" rx="70" ry="13"/><path fill="none" stroke="var(--line)" stroke-width="3" stroke-linecap="round" d="M50 151 Q111 185 203 151 M55 89 L56 66 M45 78 L67 78 M196 87 L206 76"/>'''
}
for variant in ['a','b']:
 for theme in ['paper','night']:
  line = '#8B7355' if theme=='paper' else '#9D917F'
  for food in foods:
   body=shapes[food['id']]
   if variant=='a':
    # Lighter broken-ink study with scattered pigment pooling, not a color-only variant.
    body='<g transform="translate(7 6) scale(.94)" opacity=".87">'+body+'</g><g fill="none" stroke="var(--line)" stroke-width=".9" stroke-linecap="round"><path d="M38 155 Q41 177 67 186 M174 191 Q205 184 218 162"/></g><g fill="#A5750B" opacity=".25"><ellipse cx="77" cy="126" rx="19" ry="5"/><ellipse cx="158" cy="160" rx="17" ry="7"/></g>' if food['id']!='unknown' else '<g opacity=".82">'+body+'</g>'
   svg=f'<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256" style="--line:{line}"><title>{food["name"]} — original {variant.upper()} study; not a photograph</title>{body}</svg>\n'
   (ROOT/'assets'/f'{variant}-{theme}-{food["id"]}.svg').write_text(svg)
for v in ['a','b']:
 (ROOT/f'{v}.html').write_text(f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Morsel · {v.upper()} · unshipped study</title><link rel="icon" href="data:,"><link rel="stylesheet" href="style.css"></head><body data-variant="{v}"><main id="journal"></main><dialog id="detail" aria-labelledby="detail-title"><div id="sheet"></div></dialog><script src="fixture.js"></script><script src="app.js"></script></body></html>''')
print('Generated fixture, 20 original theme/variant SVGs, and A/B HTML shells.')
