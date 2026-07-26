 const playercolors=1
 const player1colors=1
 playfieldpos=8

 dim sc0=score
 dim sc1=score+1
 dim sc2=score+2

 playfield:
 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
 X......X...X..........X.X......X
 X...X..X.....X....X.....X..X...X
 X......X..XX........XX..X......X
 X.X....X......X..X......X....X.X
 X......X...XX......XX...X......X
 X..X...X.X............X.X...X..X
 X......X....X......X....X......X
 X....X.X.......XX.......X.X....X
 X......X.XX..........XX.X......X
 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
 ................................
end

 player0:
 %00111100
 %01100110
 %01100110
 %01111110
 %01100110
 %01100110
 %01100110
 %00111100
end

 player1:
 %01111100
 %01100110
 %01100110
 %01111100
 %01100110
 %01100110
 %01100110
 %01111100
end

 player0color:
 $3e
 $4e
 $5e
 $6e
 $7e
 $8e
 $9e
 $ae
end

 player1color:
 $ce
 $be
 $ae
 $9e
 $8e
 $7e
 $6e
 $5e
end

 COLUBK=$82
 COLUPF=$2e
 CTRLPF=$21
 player0x=44
 player1x=108
 ballx=78
 missile0x=0
 missile1x=0
 player0y=78
 player1y=42
 bally=45
 player0height=7
 player1height=7
 ballheight=3
 missile0height=0
 missile1height=0
 missile0y=0
 missile1y=0
 sc0=$21
 sc1=$07
 sc2=$21
 scorecolor=$0e

main
 COLUPF=$2e
 CTRLPF=$21
 NUSIZ0=$20
 NUSIZ1=$20
 drawscreen
 goto main
