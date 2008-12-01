;************************************************************************
;*                                                                      *
;*      YAMI - Yet Another Mouse Interface                              *
;*                                                                      *
;************************************************************************
;*
;*      (C) 1998-2001 Richard Koerber
;*               http://www.shredzone.de
;*
;************************************************************************
;       This driver supports microsoft, mouse system and logitech PC
;       mouses and converts them to the Amiga quadrature pulse format.
;
;                                +---V---+
;                            WH -|1    18|- Mouse RxD
;                           WVQ -|2    17|- WV (Atari: WHQ)
;               (Atari: WV) WHQ -|3    16|- XTAL1
;                           Vpp -|4    15|- XTAL2
;                           GND -|5    14|- Vdd
;                            VQ -|6    13|- H
;                 (Atari: V) HQ -|7    12|- V (Atari: HQ)
;                     Middle MB -|8    11|- Wheel MB
;                      Right MB -|9    10|- Left MB
;                                +-------+
;
;       For the hardware see schematic.
;------------------------------------------------------------------------
;
; This program is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License
; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;
;------------------------------------------------------------------------

		LIST    p=16C84, r=dec

		DEVICE  XT_OSC, WDT_ON, PROTECT_OFF, PUT_ON     ; only PICAsm


VER             =       4                       ;Version
REV             =       2                       ;Revision

INDF            =       0x00                    ; INDirect Function
TMR0            =       0x01                    ; TMR0
STATUS          =       0x03                    ; STATUS register
FSR             =       0x04                    ; Indirect address pointer
PORTA           =       0x05                    ; PORT A
PORTB           =       0x06                    ; PORT B
EEDATA          =       0x08                    ; EEDATA
EEADR           =       0x09                    ; EEADR
OPTION          =       0x01                    ; OPTION (81)
TRISA           =       0x05                    ; TRIS A (85)
TRISB           =       0x06                    ; TRIS B (86)
EECON1          =       0x08                    ; EECON1 (88)
EECON2          =       0x09                    ; EECON2 (89)

RD              =       0
WR              =       1
WREN            =       2
WRERR           =       3
EEIF            =       4

		CBLOCK 0x10
		  loopcnt                       ;loop counter
		  bitcnt                        ;bit counter
		  serbuf                        ;serial buffer
		  portabuf                      ;Port A buffer
		  portbuf                       ;Port B buffer
		  msbbuf                        ;store of position msb
		  xposn                         ;x position to be moved to
		  yposn                         ;y position to be moved to
		  xcntr                         ;x counter
		  ycntr                         ;y counter
		  xstore                        ;temporary x store
		  mcntr                         ;movement counter
		  xposn2                        ;x position to be moved to, Queue 2
		  yposn2                        ;y position to be moved to, Queue 2
		  xcntr2                        ;x counter, Queue 2 (Wheel Queue)
		  ycntr2                        ;y counter, Queue 2 (Wheel Queue)
		  mcntr2                        ;movement counter, Queue 2 (Wheel Queue)
		  busycnt                       ;counter for wait busy loops
		  flags                         ;Internal flags
		  mode                          ;YAMI mode (AMIGA,WHEEL)
		ENDC

#define RXD     PORTA,1                         ;RXD input

#define r_b     portbuf,3                       ;right mouse button
#define m_b     portbuf,2                       ;middle mouse button
#define w_b     portbuf,5                       ;wheel mouse button
#define l_b     portbuf,4                       ;left mouse button
#define l_bport PORTB,4                         ;left mouse button, port
#define w_bport PORTB,5                         ;wheel mouse button, port

  ; Mode
#define AMIGA   mode,0                          ;0:Atari, 1:Amiga
#define WHEEL   mode,1                          ;0:No Wheel, 1:Wheel

  ; Flags
#define PULSEMODE flags,0                       ;0:prefer std, 1: prefer wheel

  ; Amiga mode
#define H       portbuf,7                       ;Horizontal Pulses
#define HQ      portbuf,1                       ;Horizontal Quadrature Pulses
#define V       portbuf,6                       ;Vertical Pulses
#define VQ      portbuf,0                       ;Vertical Quadrature Pulses

  ; Atari mode
#define ATARI_H   portbuf,7                     ;Horizontal Pulses
#define ATARI_HQ  portbuf,6                     ;Horizontal Quadrature Pulses
#define ATARI_V   portbuf,1                     ;Vertical Pulses
#define ATARI_VQ  portbuf,0                     ;Vertical Quadrature Pulses

  ; Amiga mode, wheels
#define WH      portabuf,2                      ;Wheel Horizontal Pulses
#define WHQ     portabuf,4                      ;Wheel Horizontal Quadrature Pulses
#define WV      portabuf,0                      ;Wheel Vertical Pulses
#define WVQ     portabuf,3                      ;Wheel Vertical Quadrature Pulses

  ; Atari mode
#define ATARI_WH   portabuf,2                   ;Wheel Horizontal Pulses
#define ATARI_WHQ  portabuf,0                   ;Wheel Horizontal Quadrature Pulses
#define ATARI_WV   portabuf,4                   ;Wheel Vertical Pulses
#define ATARI_WVQ  portabuf,3                   ;Wheel Vertical Quadrature Pulses


#define c       STATUS,0                        ;Carry Flag
#define z       STATUS,2                        ;Zero Flag
#define RP0     STATUS,5                        ;Register Page 0



;****************************************************************
;*      EEPROM data start here
;*
		EORG    0x00
ee_flags        de      0x02                    ;(@0x00)
		; 0x00: Atari, No Wheel
		; 0x01: Amiga, No Wheel
		; 0x03: Amiga, Wheel

		EORG    0x3E
		de      VER,REV                 ;Version and Revision


;****************************************************************
;*      The program starts here, with register initialisation
;*
		ORG     0x000

run             clrf    xcntr                   ;Clear the counters
		clrf    ycntr
		clrf    mcntr
		clrf    PORTA                   ;Low if not Tristate
		clrf    PORTB                   ;Low if not Tristate
		movlw   0xFF
		movwf   portabuf                ;Clear all output lines
		movwf   portbuf
		clrwdt                          ;Clear watchdog and prescaler
	;-- Initialize the hardware ------------;
		bsf     RP0                     ;Register Bank 1
		movlw   B'10000111'             ;No weak pull up
		movwf   OPTION                  ;  prescaler rate 1:256
		bcf     RP0                     ;Back to Register Bank 0
		movlw   0x80+TRISB              ;prepare indirect adressing
		movwf   FSR                     ;  of TRISB register
	;-- Initialize the ports ---------------;
		movf    portbuf,w               ;Initialize PORT B
		movwf   INDF                    ;  by indirect access to TRISB
		decf    FSR,f                   ;TRISA
		movf    portabuf,w              ;Initialize PORT A
		movwf   INDF                    ;  by indirect access to TRISA
		incf    FSR,f                   ;TRISB
	;-- Read the mode from EEPROM ----------;
		movlw   0x00
		call    read_eeprom
		movwf   mode
	;-- Waste 1/2 second -------------------;
		movlw   15                      ;Mouse identifier packet will
		movwf   busycnt                 ;  be skipped by this wait
iwait1          clrwdt                          ;Clear watchdog
		movf    TMR0,w                  ;Get timer 0
		btfss   z                       ;  wait until zero
		goto    iwait1                  ;  if not zero -> keep on waiting
iwait2          clrwdt                          ;Clear watchdog
		movf    TMR0,w                  ;Get timer 0
		btfsc   z                       ;  wait until not zero
		goto    iwait2
		decfsz  busycnt,f               ;Next loop
		goto    iwait1

;****************************************************************
;*      Synchronize, detect the mouse format
;*        Mouse System: 5 bytes, 8N1
;*        MicroSoft:    3 bytes, 7N1, 2 buttons
;*        Logitech:     like MicroSoft, optional 4th byte, 3 buttons, optional wheel
;*
synchronize     call    rcb                     ;receive the start byte
reentry         clrwdt                          ;Clear watchdog
		btfsc   serbuf,6                ;bit 6 is set for MS/Logitech
		goto    microsoft
		btfss   serbuf,7                ;bit 7 MUST be set for Mouse Systems
		goto    synchronize
		movf    serbuf,w
		andlw   B'00111000'             ;bit 5-3 must be 0 for mouse synch
		btfss   z
		goto    synchronize             ;nope: try next byte
		; PC continues here if Mouse System detected !

;****************************************************************
;*      Mouse System format
;*              Valid byte has already been read
;*
mouse   ;-- Set the mouse buttons --------------;0=pressed!
		bcf     r_b                     ;RMB
		btfsc   serbuf,0                ;  pressed
		bsf     r_b                     ;  released
		bcf     m_b                     ;MMB
		btfsc   AMIGA                   ;  always release in ATARI mode
		btfsc   serbuf,1                ;  pressed
		bsf     m_b                     ;  released
		bcf     l_b                     ;LMB
		btfsc   serbuf,2                ;  pressed
		bsf     l_b                     ;  released
		; port will be set during fetch of the next byte

	;-- Second and third byte --------------;
		call    rcb                     ;xposn, X-Axis movement data
		movf    serbuf,w
		movwf   xstore                  ;  store it
		call    rcb                     ;yposn, Y-Axis movement data
		movf    serbuf,w
		movwf   yposn                   ;set Y position
		movf    xstore,w                ;and X position from xstore
		movwf   xposn
		clrf    xcntr
		clrf    ycntr
		movlw   0x81                    ;start 128 movements
		movwf   mcntr

	;-- Fourth and fifth byte --------------;
		call    rcb                     ;byte3, X-Axis movement data, fine
		movf    serbuf,w
		movwf   xstore                  ;  store it
		call    rcb                     ;byte4, Y-Axis movement data, fine
		movf    serbuf,w
		movwf   yposn                   ;set Y position
		movf    xstore,w                ;and X position from xstore
		movwf   xposn
		clrf    xcntr
		clrf    ycntr
		movlw   0x81                    ;start 128 movements
		movwf   mcntr

		goto    synchronize             ;re-synchronize again

;****************************************************************
;*      Check MicroSoft and Logitech format
;*              Valid byte has already been read
;*
microsoft
	;-- Set LMB and RMB --------------------;
		movf    serbuf,w                ;get first byte again
		movwf   msbbuf                  ;store as msbbuf (MSB of X/Y movement data)

		bcf     r_b                     ;check right mouse button
		btfss   serbuf,4                ;  pressed
		bsf     r_b                     ;  released
		bcf     l_b                     ;check left mouse button
		btfss   serbuf,5                ;  pressed
		bsf     l_b                     ;  released
		; port will be set appropriately during fetch of the next byte

	;-- Second byte ------------------------;
		call    rcb                     ;receive second byte
		btfsc   serbuf,6                ;bit 6 must be 0 for LogiTech
		goto    reentry                 ;if not zero -> synchronize

		movf    serbuf,w                ;move x0-x5 from serbuf to xposn
		movwf   xstore                  ;x6 is 0, x7 is 1 now
		btfsc   msbbuf,0                ;move x6 from msbbuf to xposn
		bsf     xstore,6
		btfss   msbbuf,1                ;move x7 from msbbuf to xposn
		bcf     xstore,7

	;-- Third byte -------------------------;
		call    rcb                     ;receive third byte
		btfsc   serbuf,6                ;bit 6 must be 0 for LogiTech
		goto    reentry                 ;if not zero -> synchronize

		comf    serbuf,w                ;move y0-y5 from serbuf to yposn (inversed)
		movwf   yposn                   ;y6 is 1, y7 is 0 now
		btfsc   msbbuf,2                ;move y6 from msbbuf to yposn (inversed)
		bcf     yposn,6
		btfss   msbbuf,3                ;move y7 from msbbuf to yposn (inversed)
		bsf     yposn,7
		incf    yposn,f                 ;produce a 2-complement

	;-- Speed limit ------------------------;
		movf    yposn,w
		btfsc   yposn,7
		goto    ylimneg
		btfsc   yposn,6
		movlw   0x40                    ; %01000000
		goto    ylimdone
ylimneg:        btfss   yposn,6
		movlw   0xBF                    ; %10111111
ylimdone:       movwf   yposn
		movf    xstore,w
		btfsc   xstore,7
		goto    xlimneg
		btfsc   xstore,6
		movlw   0x40                    ; %01000000
		goto    xlimdone
xlimneg:        btfss   xstore,6
		movlw   0xBF                    ; %10111111
xlimdone:       movwf   xposn

		clrf    xcntr
		clrf    ycntr
		movlw   0x81                    ;start 128 movements
		movwf   mcntr
		; Amiga mouse will be pulsed during fetch of the next byte

	;-- Optional fourth byte ---------------;
		call    rcb                     ;receive optional fourth byte
		bsf     m_b                     ;middle mouse button released by default
		bsf     w_b                     ;wheel button released by default
		btfsc   serbuf,6                ;bit 6 must be 0 for LogiTech
		goto    reentry                 ;if not zero -> synchronize

		btfss   AMIGA                   ;in ATARI mode
		goto    no_mmb                  ;  ignore MMB/WMB
		btfsc   serbuf,5                ;check middle mouse button
		bcf     m_b                     ;  pressed
		btfsc   serbuf,4                ;check wheel button
		bcf     w_b                     ;  pressed
no_mmb
		movf    serbuf,w                ;Get wheel movement
		andlw   B'00001111'             ;  only bit 0~3 required
		btfsc   z
		goto    synchronize             ;  if zero -> synchronize

		btfsc   serbuf,3                ;Sign extend the nibble to byte
		iorlw   B'11110000'
		xorlw   B'11111111'             ;  2 complement
		addlw   1
		movwf   yposn2                  ;  set Y movement
		clrf    xposn2                  ;no X movement
		clrf    xcntr2
		clrf    ycntr2
		movlw   0x81                    ;start 128 movements
		movwf   mcntr2                  ; Everything in Queue 2, so it is deferred until there
						; is enough time to process

	;-- Expect a fifth byte ----------------;
		call    rcb                     ; receive optional fifth byte
		btfsc   serbuf,6                ;bit 6 must be 0 for fifth byte
		goto    reentry

		; Fifth byte: horizontal Wheel, fifth and sixth button?
		; Ignore it...

		goto    synchronize             ;and start synchronizing again

;****************************************************************
;*      Receive 8 bits
;*        Returns only when byte is received
;*        Proof of 7 bit transmittions
;*        At least two rcb are required to perform a full 128
;*        step mouse move!
;*
	; INST = instructions per bit at 1200 baud
	;            (833 @4MHz)
	; CALL = waitquad duration (100)
	; SKIPVAL = Floor(((INST/4)-3)/(CALL+4))
	; BITVAL  = (INST-8)/(CALL+BITNOP+3)
	; SKIPVAL + 8BITVAL must be > 64

rcb             clrwdt                          ;Clear watchdog
		call    waitquad                ;Wait and do one quad pulse
		call    checkjoy                ;  no: test for joystick
		btfss   RXD                     ;Start bit found?
		goto    rcb                     ;  no: wait for start bit
	;-- Skip start bit ---------------------;
	; We don't skip to the mid of the start bit
	; because we won't lose precious time for all
	; calculations between two rcb calls.
		movlw   2                       ;<- SKIPVAL
		movwf   loopcnt
do_hbit         call    waitquad                ;  and generate quad pulses
		clrwdt                          ;Clear watchdog (included in SKIPNOP)
		decfsz  loopcnt,f
		goto    do_hbit
	;-- Shift 8 bits -----------------------;
		movlw   8                       ;Set bit counter
		movwf   bitcnt
i_loop          movlw   8                       ;<- BITVAL
		movwf   loopcnt                 ;  Skip the time of one bit
r_loop          call    waitquad                ;  and generate quad pulses
;                clrwdt                          ;<- BITNOP
		decfsz  loopcnt,f
		goto    r_loop
		bcf     c                       ;move RXD into c
		btfss   RXD                     ; and invert it (RS232->TTL)
		bsf     c
		rrf     serbuf,f                ;rotate c in serbuf
		decfsz  bitcnt,f                ;do it with all 8 bytes
		goto    i_loop                  ;10 inst cycles each loop
	;-- Wait for stop bit ------------------;
waitlow         clrwdt                          ;Clear watchdog
	; Don't do any waitquad here, we will lose too much time.
		btfsc   RXD                     ;wait for RXD = 0
		goto    waitlow                 ;  Stop bit? (auto synchronisation)
	;-- Done -------------------------------;
		return

;****************************************************************
;*      Wait a definite amount of time and do one quad pulse
;*        The mouse position or wheel position is moved one
;*        step, by generating quad pulse modulated impulses
;*        on V,VQ,H,HQ,WV,WVQ,WH,WHQ respectively. The mouse
;*        buttons are also updated when a mouse quad pulse
;*        is generated.
;*        This call consumes exactly 100 instruction cycles
;*        in any case.
;*
waitquad        btfsc   PULSEMODE               ;  0    What mode?
		goto    prefer_wheel            ;
		nop                             ;
	;-- Prefer pulse mode ------------------;
		bsf     PULSEMODE               ;  3    Wheel preferred next time...
		movf    mcntr,w                 ;       read the mouse move counter
		btfss   z                       ;         <> 0 ?
		goto    do_mousequad2           ;         yes: do one mouse quad pulse
		movf    mcntr2,w                ;  7    read the wheel move counter
		btfss   z                       ;         <> 0 ?
		goto    do_wheelquad            ;         yes: do one wheel quad pulse
		goto    do_wastetime            ; 10    else waste time
	;-- Prefer wheel mode ------------------;
prefer_wheel    bcf     PULSEMODE               ;  3    Mouse preferred next time...
		movf    mcntr2,w                ;       read the wheel move counter
		btfss   z                       ;         <> 0 ?
		goto    do_wheelquad2           ;         yes: do one wheel quad pulse
		movf    mcntr,w                 ;  7    read the mouse move counter
		btfss   z                       ;         <> 0 ?
		goto    do_mousequad            ;         yes: do one mouse quad pulse
		goto    do_wastetime            ; 10    else waste time

	;-- Do one mouse quadrature pulse ------;
do_mousequad2   nop                             ;  8    +3 for synchronization
		nop
		nop                             ;
do_mousequad    call    mousequad               ; 11    +1+47 cycles
		movlw   7                       ; 59
		nop                             ; 60
		goto    do_waste                ; 61    +2

	;-- Do one wheel quadrature pulse ------;
do_wheelquad2   nop                             ;  8    +3 for synchronization
		nop
		nop                             ;
do_wheelquad    btfss   WHEEL                   ; 11    no mouse wheels:
		goto    do_nowheel              ;         don't move them...
		call    wheelquad               ; 13    +1+49 cycles
		nop                             ; 63
		nop                             ; 64
		movlw   6                       ; 65
		goto    do_waste                ; 66
	;-- No Wheel supported -----------------;
do_nowheel      decf    mcntr2,f                ; 14    just decrement the counter
		movlw   16
		goto    do_waste                ; 16    +2

	;-- No movement ------------------------;
do_wastetime    movlw   17                      ; 12    Waste an entire period

	; wastes (w*5)+2 cycles, return inclusive
do_waste        movwf   busycnt
do_wasteloop    clrwdt
		nop
		decfsz  busycnt,f
		goto    do_wasteloop            ;       5 cycles each loop, -1 for leaving
		return                          ; 98    +2 for the return

;****************************************************************
;*      Wait a definite amount of time and do one quad pulse
;*        on the mouse wheel lines. During this time, the serial
;*        position (xposn, yposn) is converted to Amiga quadrature
;*        modulation. Every change on WV, WVQ, WH, WHQ is one
;*        mouse wheel move. Mouse buttons are *not* updated!
;*        This call takes exactly - 47 - instruction cycles
;*        in ANY case (return included).
;*
mousequad       decf    mcntr,f                 ;  decrement the counter

	; consumes 46 instructions in any case
		btfss   AMIGA                   ;ATARI mode?
		goto    atari_mode              ; then jump to atari mode

	; -- AMIGA MODE --
	; The following x_axis and y_axis movement code consumes
	;   44 instruction cycles -exactly- in -any- case (return inclusive)
	;-- Check the X axis -------------------;
x_axis          movf    xposn,w                 ;fetch desired X position
		btfsc   z                       ;  = 0 ?
		goto    x_axis_4                ;  no X move, just wait
		addwf   xcntr,f                 ;add to the X counter (signed)
		btfsc   xposn,7                 ;check direction
		goto    left                    ;negative: to the left
	;---- Move X to the right --------------;
right           btfss   xcntr,7                 ;X counter overflow?
		goto    x_axis_9                ;  no: just do nothing
		bcf     xcntr,7                 ;X counter -= 128
		btfsc   H
		goto    right_h1                ;H=1 -> right_h1
		btfss   HQ
		bsf     H                       ;H=0 HQ=0 -> H=1
		btfsc   HQ
		bcf     HQ                      ;H=0 HQ=1 -> HQ=0
		goto    x_axis_17
right_h1        btfsc   HQ
		bcf     H                       ;H=1 HQ=1 -> H=0
		btfss   HQ
		bsf     HQ                      ;H=1 HQ=0 -> HQ=1
		goto    x_axis_18
	;---- Move X to the left ---------------;
left            btfsc   xcntr,7                 ;X counter underflow?
		goto    x_axis_10               ;  no: just do nothing
		bsf     xcntr,7                 ;X counter += 128
		btfsc   H
		goto    left_h1                 ;H=1 -> left_h1
		btfsc   HQ
		bsf     H                       ;H=0 HQ=1 -> H=1
		btfss   HQ
		bsf     HQ                      ;H=0 HQ=0 -> HQ=1
		goto    x_axis_18
left_h1         btfss   HQ
		bcf     H                       ;H=1 HQ=0 -> H=0
		btfsc   HQ
		bcf     HQ                      ;H=1 HQ=1 -> HQ=0
		goto    x_axis_19
	;---- X axis cycle burndown ------------;
x_axis_4        nop                             ; 4 cycles
		nop                             ; 5 cycles
		nop                             ; 6 cycles
		nop                             ; 7 cycles
		nop                             ; 8 cycles
x_axis_9        nop                             ; 9 cycles
x_axis_10       nop                             ;10 cycles
		nop                             ;11 cycles
		nop                             ;12 cycles
		nop                             ;13 cycles
		nop                             ;14 cycles
		nop                             ;15 cycles
		nop                             ;16 cycles
x_axis_17       nop                             ;17 cycles
x_axis_18       nop                             ;18 cycles
x_axis_19
	;-- Check the Y axis -------------------;
y_axis          movf    yposn,w                 ;fetch desired Y position
		btfsc   z                       ;  = 0 ?
		goto    y_axis_4                ;  no Y move, just wait
		addwf   ycntr,f                 ;add to the Y counter (signed)
		btfsc   yposn,7                 ;check direction
		goto    down                    ;negative: down
	;---- Move Y up ------------------------;
up              btfss   ycntr,7                 ;Y counter overflow?
		goto    y_axis_9                ;  no: just do nothing
		bcf     ycntr,7                 ;Y counter -= 128
		btfsc   V
		goto    up_v1                   ;V=1 -> up_v1
		btfsc   VQ
		bsf     V                       ;V=0 VQ=1 -> V=1
		btfss   VQ
		bsf     VQ                      ;V=0 VQ=0 -> VQ=1
		goto    y_axis_17
up_v1           btfss   VQ
		bcf     V                       ;V=1 VQ=0 -> V=0
		btfsc   VQ
		bcf     VQ                      ;V=1 VQ=1 -> VQ=0
		goto    y_axis_18
	;---- Move Y down ----------------------;
down            btfsc   ycntr,7                 ;Y counter underflow?
		goto    y_axis_10               ;  no: just do nothing
		bsf     ycntr,7                 ;Y counter += 128
		btfsc   V
		goto    down_v1                 ;V=1 -> down_v1
		btfss   VQ
		bsf     V                       ;V=0 VQ=0 -> V=1
		btfsc   VQ
		bcf     VQ                      ;V=0 VQ=1 -> VQ=0
		goto    y_axis_18
down_v1         btfsc   VQ
		bcf     V                       ;V=1 VQ=1 -> V=0
		btfss   VQ
		bsf     VQ                      ;V=1 VQ=0 -> VQ=1
		goto    y_axis_19
	;---- Y axis cycle burndown ------------;
y_axis_4        nop                             ; 4 cycles
		nop                             ; 5 cycles
		nop                             ; 6 cycles
		nop                             ; 7 cycles
		nop                             ; 8 cycles
y_axis_9        nop                             ; 9 cycles
y_axis_10       nop                             ;10 cycles
		nop                             ;11 cycles
		nop                             ;12 cycles
		nop                             ;13 cycles
		nop                             ;14 cycles
		nop                             ;15 cycles
		nop                             ;16 cycles
y_axis_17       nop                             ;17 cycles
y_axis_18       nop                             ;18 cycles
y_axis_19       goto    wq_update


	; -- ATARI MODE --
	; The following x_axis and y_axis movement code consumes
	;   43 instruction cycles -exactly- in -any- case.
atari_mode      nop                             ; waste one cycle to catch up
	;-- Check the X axis -------------------;
a_x_axis        movf    xposn,w                 ;fetch desired X position
		btfsc   z                       ;  = 0 ?
		goto    a_x_axis_4              ;  no X move, just wait
		addwf   xcntr,f                 ;add to the X counter (signed)
		btfsc   xposn,7                 ;check direction
		goto    a_left                  ;negative: to the left
	;---- Move X to the right --------------;
a_right         btfss   xcntr,7                 ;X counter overflow?
		goto    a_x_axis_9              ;  no: just do nothing
		bcf     xcntr,7                 ;X counter -= 128
		btfsc   ATARI_H
		goto    a_right_h1              ;H=1 -> right_h1
		btfss   ATARI_HQ
		bsf     ATARI_H                 ;H=0 HQ=0 -> H=1
		btfsc   ATARI_HQ
		bcf     ATARI_HQ                ;H=0 HQ=1 -> HQ=0
		goto    a_x_axis_17
a_right_h1      btfsc   ATARI_HQ
		bcf     ATARI_H                 ;H=1 HQ=1 -> H=0
		btfss   ATARI_HQ
		bsf     ATARI_HQ                ;H=1 HQ=0 -> HQ=1
		goto    a_x_axis_18
	;---- Move X to the left ---------------;
a_left          btfsc   xcntr,7                 ;X counter underflow?
		goto    a_x_axis_10             ;  no: just do nothing
		bsf     xcntr,7                 ;X counter += 128
		btfsc   ATARI_H
		goto    a_left_h1               ;H=1 -> left_h1
		btfsc   ATARI_HQ
		bsf     ATARI_H                 ;H=0 HQ=1 -> H=1
		btfss   ATARI_HQ
		bsf     ATARI_HQ                ;H=0 HQ=0 -> HQ=1
		goto    a_x_axis_18
a_left_h1       btfss   ATARI_HQ
		bcf     ATARI_H                 ;H=1 HQ=0 -> H=0
		btfsc   ATARI_HQ
		bcf     ATARI_HQ                ;H=1 HQ=1 -> HQ=0
		goto    a_x_axis_19
	;---- X axis cycle burndown ------------;
a_x_axis_4      nop                             ; 4 cycles
		nop                             ; 5 cycles
		nop                             ; 6 cycles
		nop                             ; 7 cycles
		nop                             ; 8 cycles
a_x_axis_9      nop                             ; 9 cycles
a_x_axis_10     nop                             ;10 cycles
		nop                             ;11 cycles
		nop                             ;12 cycles
		nop                             ;13 cycles
		nop                             ;14 cycles
		nop                             ;15 cycles
		nop                             ;16 cycles
a_x_axis_17     nop                             ;17 cycles
a_x_axis_18     clrwdt                          ;18 cycles
a_x_axis_19
	;-- Check the Y axis -------------------;
a_y_axis        movf    yposn,w                 ;fetch desired Y position
		btfsc   z                       ;  = 0 ?
		goto    a_y_axis_4              ;  no Y move, just wait
		addwf   ycntr,f                 ;add to the Y counter (signed)
		btfsc   yposn,7                 ;check direction
		goto    a_down                  ;negative: down
	;---- Move Y up ------------------------;
a_up            btfss   ycntr,7                 ;Y counter overflow?
		goto    a_y_axis_9              ;  no: just do nothing
		bcf     ycntr,7                 ;Y counter -= 128
		btfsc   ATARI_V
		goto    a_up_v1                 ;V=1 -> up_v1
		btfsc   ATARI_VQ
		bsf     ATARI_V                 ;V=0 VQ=1 -> V=1
		btfss   ATARI_VQ
		bsf     ATARI_VQ                ;V=0 VQ=0 -> VQ=1
		goto    a_y_axis_17
a_up_v1         btfss   ATARI_VQ
		bcf     ATARI_V                 ;V=1 VQ=0 -> V=0
		btfsc   ATARI_VQ
		bcf     ATARI_VQ                ;V=1 VQ=1 -> VQ=0
		goto    a_y_axis_18
	;---- Move Y down ----------------------;
a_down          btfsc   ycntr,7                 ;Y counter underflow?
		goto    a_y_axis_10             ;  no: just do nothing
		bsf     ycntr,7                 ;Y counter += 128
		btfsc   ATARI_V
		goto    a_down_v1               ;V=1 -> down_v1
		btfss   ATARI_VQ
		bsf     ATARI_V                 ;V=0 VQ=0 -> V=1
		btfsc   ATARI_VQ
		bcf     ATARI_VQ                ;V=0 VQ=1 -> VQ=0
		goto    a_y_axis_18
a_down_v1       btfsc   ATARI_VQ
		bcf     ATARI_V                 ;V=1 VQ=1 -> V=0
		btfss   ATARI_VQ
		bsf     ATARI_VQ                ;V=1 VQ=0 -> VQ=1
		goto    a_y_axis_19
	;---- Y axis cycle burndown ------------;
a_y_axis_4      nop                             ; 4 cycles
		nop                             ; 5 cycles
		nop                             ; 6 cycles
		nop                             ; 7 cycles
		nop                             ; 8 cycles
a_y_axis_9      nop                             ; 9 cycles
a_y_axis_10     nop                             ;10 cycles
		nop                             ;11 cycles
		nop                             ;12 cycles
		nop                             ;13 cycles
		nop                             ;14 cycles
		nop                             ;15 cycles
		nop                             ;16 cycles
a_y_axis_17     nop                             ;17 cycles
a_y_axis_18     clrwdt                          ;18 cycles
a_y_axis_19

	;-- Update the mouse port --------------;
wq_update       movf    portbuf,w               ;46 cycles are consumed here
		movwf   INDF                    ;update Port B (indirect TRISB)

	;-- Done -------------------------------;
		return

	;-- Just waste time --------------------;
waste_time      movlw   7                       ;Skip the time of one bit
		movwf   busycnt                 ;  42 instruction cycles are
waste_loop      nop                             ;  required to do the job
		nop
		decfsz  busycnt,f
		goto    waste_loop
		nop
		nop
		nop
		nop
		goto    wq_update               ;update port and return


;****************************************************************
;*      Wait a definite amount of time and do one quad pulse
;*        on the mouse wheel lines. During this time, the serial
;*        position (xposn, yposn) is converted to Amiga quadrature
;*        modulation. Every change on WV, WVQ, WH, WHQ is one
;*        mouse wheel move. Mouse buttons are *not* updated!
;*        This call takes exactly - 49 - instruction cycles
;*        in ANY case (return included).
;*
wheelquad       decf    mcntr2,f                ;  decrement the counter

	; consumes 48 instructions in any case
		btfss   AMIGA                   ;ATARI mode?
		goto    wh_atari_mode           ; then jump to atari mode

	; -- AMIGA MODE --
	; The following x_axis and y_axis movement code consumes
	;   46 instruction cycles -exactly- in -any- case (return inclusive)
	;-- Check the X axis -------------------;
wh_x_axis       movf    xposn2,w                ;fetch desired X position
		btfsc   z                       ;  = 0 ?
		goto    wh_x_axis_4             ;  no X move, just wait
		addwf   xcntr2,f                ;add to the X counter (signed)
		btfsc   xposn2,7                ;check direction
		goto    wh_left                 ;negative: to the left
	;---- Move X to the right --------------;
wh_right        btfss   xcntr2,7                ;X counter overflow?
		goto    wh_x_axis_9             ;  no: just do nothing
		bcf     xcntr2,7                ;X counter -= 128
		btfsc   WH
		goto    wh_right_h1             ;WH=1 -> right_h1
		btfss   WHQ
		bsf     WH                      ;WH=0 WHQ=0 -> WH=1
		btfsc   WHQ
		bcf     WHQ                     ;WH=0 WHQ=1 -> WHQ=0
		goto    wh_x_axis_17
wh_right_h1     btfsc   WHQ
		bcf     WH                      ;WH=1 WHQ=1 -> WH=0
		btfss   WHQ
		bsf     WHQ                     ;WH=1 WHQ=0 -> WHQ=1
		goto    wh_x_axis_18
	;---- Move X to the left ---------------;
wh_left         btfsc   xcntr2,7                ;X counter underflow?
		goto    wh_x_axis_10            ;  no: just do nothing
		bsf     xcntr2,7                ;X counter += 128
		btfsc   WH
		goto    wh_left_h1              ;WH=1 -> left_h1
		btfsc   WHQ
		bsf     WH                      ;WH=0 WHQ=1 -> WH=1
		btfss   WHQ
		bsf     WHQ                     ;WH=0 WHQ=0 -> WHQ=1
		goto    wh_x_axis_18
wh_left_h1      btfss   WHQ
		bcf     WH                      ;H=1 HQ=0 -> H=0
		btfsc   WHQ
		bcf     WHQ                     ;H=1 HQ=1 -> HQ=0
		goto    wh_x_axis_19
	;---- X axis cycle burndown ------------;
wh_x_axis_4     nop                             ; 4 cycles
		nop                             ; 5 cycles
		nop                             ; 6 cycles
		nop                             ; 7 cycles
		nop                             ; 8 cycles
wh_x_axis_9     nop                             ; 9 cycles
wh_x_axis_10    nop                             ;10 cycles
		nop                             ;11 cycles
		nop                             ;12 cycles
		nop                             ;13 cycles
		nop                             ;14 cycles
		nop                             ;15 cycles
		nop                             ;16 cycles
wh_x_axis_17    nop                             ;17 cycles
wh_x_axis_18    nop                             ;18 cycles
wh_x_axis_19
	;-- Check the Y axis -------------------;
wh_y_axis       movf    yposn2,w                ;fetch desired Y position
		btfsc   z                       ;  = 0 ?
		goto    wh_y_axis_4             ;  no Y move, just wait
		addwf   ycntr2,f                ;add to the Y counter (signed)
		btfsc   yposn2,7                ;check direction
		goto    wh_down                 ;negative: down
	;---- Move Y up ------------------------;
wh_up           btfss   ycntr2,7                ;Y counter overflow?
		goto    wh_y_axis_9             ;  no: just do nothing
		bcf     ycntr2,7                ;Y counter -= 128
		btfsc   WV
		goto    wh_up_v1                ;WV=1 -> up_v1
		btfsc   WVQ
		bsf     WV                      ;WV=0 WVQ=1 -> WV=1
		btfss   WVQ
		bsf     WVQ                     ;WV=0 WVQ=0 -> WVQ=1
		goto    wh_y_axis_17
wh_up_v1        btfss   WVQ
		bcf     WV                      ;WV=1 WVQ=0 -> WV=0
		btfsc   WVQ
		bcf     WVQ                     ;WV=1 WVQ=1 -> WVQ=0
		goto    wh_y_axis_18
	;---- Move Y down ----------------------;
wh_down         btfsc   ycntr2,7                ;Y counter underflow?
		goto    wh_y_axis_10            ;  no: just do nothing
		bsf     ycntr2,7                ;Y counter += 128
		btfsc   WV
		goto    wh_down_v1              ;WV=1 -> down_v1
		btfss   WVQ
		bsf     WV                      ;WV=0 WVQ=0 -> WV=1
		btfsc   WVQ
		bcf     WVQ                     ;WV=0 WVQ=1 -> WVQ=0
		goto    wh_y_axis_18
wh_down_v1      btfsc   WVQ
		bcf     WV                      ;WV=1 WVQ=1 -> WV=0
		btfss   WVQ
		bsf     WVQ                     ;WV=1 WVQ=0 -> WVQ=1
		goto    wh_y_axis_19
	;---- Y axis cycle burndown ------------;
wh_y_axis_4     nop                             ; 4 cycles
		nop                             ; 5 cycles
		nop                             ; 6 cycles
		nop                             ; 7 cycles
		nop                             ; 8 cycles
wh_y_axis_9     nop                             ; 9 cycles
wh_y_axis_10    nop                             ;10 cycles
		nop                             ;11 cycles
		nop                             ;12 cycles
		nop                             ;13 cycles
		nop                             ;14 cycles
		nop                             ;15 cycles
		nop                             ;16 cycles
wh_y_axis_17    nop                             ;17 cycles
wh_y_axis_18    nop                             ;18 cycles
wh_y_axis_19    goto    wh_wq_update


	; -- ATARI MODE --
	; The following x_axis and y_axis movement code consumes
	;   45 instruction cycles -exactly- in -any- case.
wh_atari_mode   nop                             ; waste one cycle to catch up
	;-- Check the X axis -------------------;
wh_a_x_axis     movf    xposn2,w                ;fetch desired X position
		btfsc   z                       ;  = 0 ?
		goto    wh_a_x_axis_4           ;  no X move, just wait
		addwf   xcntr2,f                ;add to the X counter (signed)
		btfsc   xposn2,7                ;check direction
		goto    wh_a_left               ;negative: to the left
	;---- Move X to the right --------------;
wh_a_right      btfss   xcntr2,7                ;X counter overflow?
		goto    wh_a_x_axis_9           ;  no: just do nothing
		bcf     xcntr2,7                ;X counter -= 128
		btfsc   ATARI_WH
		goto    wh_a_right_h1           ;WH=1 -> right_h1
		btfss   ATARI_WHQ
		bsf     ATARI_WH                ;WH=0 WHQ=0 -> WH=1
		btfsc   ATARI_WHQ
		bcf     ATARI_WHQ               ;WH=0 WHQ=1 -> WHQ=0
		goto    wh_a_x_axis_17
wh_a_right_h1   btfsc   ATARI_WHQ
		bcf     ATARI_WH                ;WH=1 WHQ=1 -> WH=0
		btfss   ATARI_WHQ
		bsf     ATARI_WHQ               ;WH=1 WHQ=0 -> WHQ=1
		goto    wh_a_x_axis_18
	;---- Move X to the left ---------------;
wh_a_left       btfsc   xcntr2,7                ;X counter underflow?
		goto    wh_a_x_axis_10          ;  no: just do nothing
		bsf     xcntr2,7                ;X counter += 128
		btfsc   ATARI_WH
		goto    wh_a_left_h1            ;WH=1 -> left_h1
		btfsc   ATARI_WHQ
		bsf     ATARI_WH                ;WH=0 WHQ=1 -> WH=1
		btfss   ATARI_WHQ
		bsf     ATARI_WHQ               ;WH=0 WHQ=0 -> WHQ=1
		goto    wh_a_x_axis_18
wh_a_left_h1    btfss   ATARI_WHQ
		bcf     ATARI_WH                ;WH=1 WHQ=0 -> WH=0
		btfsc   ATARI_WHQ
		bcf     ATARI_WHQ               ;WH=1 WHQ=1 -> WHQ=0
		goto    wh_a_x_axis_19
	;---- X axis cycle burndown ------------;
wh_a_x_axis_4   nop                             ; 4 cycles
		nop                             ; 5 cycles
		nop                             ; 6 cycles
		nop                             ; 7 cycles
		nop                             ; 8 cycles
wh_a_x_axis_9   nop                             ; 9 cycles
wh_a_x_axis_10  nop                             ;10 cycles
		nop                             ;11 cycles
		nop                             ;12 cycles
		nop                             ;13 cycles
		nop                             ;14 cycles
		nop                             ;15 cycles
		nop                             ;16 cycles
wh_a_x_axis_17  nop                             ;17 cycles
wh_a_x_axis_18  clrwdt                          ;18 cycles
wh_a_x_axis_19
	;-- Check the Y axis -------------------;
wh_a_y_axis     movf    yposn2,w                ;fetch desired Y position
		btfsc   z                       ;  = 0 ?
		goto    wh_a_y_axis_4           ;  no Y move, just wait
		addwf   ycntr2,f                ;add to the Y counter (signed)
		btfsc   yposn2,7                ;check direction
		goto    wh_a_down               ;negative: down
	;---- Move Y up ------------------------;
wh_a_up         btfss   ycntr2,7                ;Y counter overflow?
		goto    wh_a_y_axis_9           ;  no: just do nothing
		bcf     ycntr2,7                ;Y counter -= 128
		btfsc   ATARI_WV
		goto    wh_a_up_v1              ;WV=1 -> up_v1
		btfsc   ATARI_WVQ
		bsf     ATARI_WV                ;WV=0 WVQ=1 -> WV=1
		btfss   ATARI_WVQ
		bsf     ATARI_WVQ               ;WV=0 WVQ=0 -> WVQ=1
		goto    wh_a_y_axis_17
wh_a_up_v1      btfss   ATARI_WVQ
		bcf     ATARI_WV                ;WV=1 WVQ=0 -> WV=0
		btfsc   ATARI_WVQ
		bcf     ATARI_WVQ               ;WV=1 WVQ=1 -> WVQ=0
		goto    wh_a_y_axis_18
	;---- Move Y down ----------------------;
wh_a_down       btfsc   ycntr2,7                ;Y counter underflow?
		goto    wh_a_y_axis_10          ;  no: just do nothing
		bsf     ycntr2,7                ;Y counter += 128
		btfsc   ATARI_WV
		goto    wh_a_down_v1            ;WV=1 -> down_v1
		btfss   ATARI_WVQ
		bsf     ATARI_WV                ;WV=0 WVQ=0 -> WV=1
		btfsc   ATARI_WVQ
		bcf     ATARI_WVQ               ;WV=0 WVQ=1 -> WVQ=0
		goto    wh_a_y_axis_18
wh_a_down_v1    btfsc   ATARI_WVQ
		bcf     ATARI_WV                ;WV=1 WVQ=1 -> WV=0
		btfss   ATARI_WVQ
		bsf     ATARI_WVQ               ;WV=1 WVQ=0 -> WVQ=1
		goto    wh_a_y_axis_19
	;---- Y axis cycle burndown ------------;
wh_a_y_axis_4   nop                             ; 4 cycles
		nop                             ; 5 cycles
		nop                             ; 6 cycles
		nop                             ; 7 cycles
		nop                             ; 8 cycles
wh_a_y_axis_9   nop                             ; 9 cycles
wh_a_y_axis_10  nop                             ;10 cycles
		nop                             ;11 cycles
		nop                             ;12 cycles
		nop                             ;13 cycles
		nop                             ;14 cycles
		nop                             ;15 cycles
		nop                             ;16 cycles
wh_a_y_axis_17  nop                             ;17 cycles
wh_a_y_axis_18  clrwdt                          ;18 cycles
wh_a_y_axis_19

	;-- Update the mouse wheel port --------;
wh_wq_update    movf    portabuf,w              ;46 cycles are consumed here
		decf    FSR,f                   ;TRISA
		movwf   INDF                    ;update Port A (indirect TRISA)
		incf    FSR,f                   ;back to TRISB

	;-- Done -------------------------------;
		return

	;-- Just waste time --------------------;
wh_waste_time   movlw   8                       ;Skip the time of one bit
		movwf   busycnt                 ;  44 instruction cycles are
wh_waste_loop   nop                             ;  required to do the job
		nop
		decfsz  busycnt,f
		goto    wh_waste_loop
		nop
		goto    wh_wq_update            ;update port and return


;****************************************************************
;*      Test if a parallel joystick is triggered. If so, go
;*        to tri-state with the appropriate port. The next
;*        mouse move will turn the signals online again.
;*
checkjoy
	;-- Check if joystick is triggered -----;
		btfss   l_b                     ;Left MB in tristate?
		goto    joy_wheel               ;  no: check joy_wheel
		bsf     INDF,4                  ;Set LMB to tristate...
		nop                             ;Allow the change to be made
		nop                             ;  (this is due to the PIC prefetch queues)
		btfsc   l_bport                 ;Check LMB port, should be high now
		goto    joy_wheel               ;  not pressed: joy_wheel
	;-- Mouse to tristate ------------------;
		clrf    xposn                   ;Clear the counter, so there are no more moves to do
		clrf    yposn
		movlw   0xFF                    ;set Port B to tri state
		movwf   INDF
	;-- Check if 2nd joystick is triggered -;
joy_wheel       btfss   w_b                     ;Wheel MB in tristate?
		return                          ;  nope:leave
		bsf     INDF,5                  ;Set WMB to tristate...
		nop                             ;Allow the change to be made
		nop                             ;  (this is due to the PIC prefetch queues)
		btfsc   w_bport                 ;Check WMB port, should be high now
		return                          ;  not pressed: leavae
	;-- Wheel to tristate ------------------;
		clrf    xposn2                  ;Clear the counter, so there are no more moves to do
		clrf    yposn2
		decf    FSR,f                   ;TRISA
		movlw   0xFF                    ;set Port A to tri state
		movwf   INDF
		incf    FSR,f                   ;TRISB
		return

;****************************************************************
;*      Reads a byte from the EEPROM
;*        -> W  Address
;*        <- W  Data
;*
read_eeprom     movwf   EEADR                   ;write address
		bsf     RP0
		bsf     EECON1,RD               ;trigger reading
		bcf     RP0
		movf    EEDATA,w                ;get data
		return



		END



;****************************************************************

