;************************************************************************
;*                                                                      *
;*      YAMI - Yet Another Mouse Interface                              *
;*                                                                      *
;************************************************************************
;*
;*      (C) 1998-2021 Richard Koerber
;*               https://yami.shredzone.org
;*
;************************************************************************
;       This driver supports microsoft, mouse system and logitech PC
;       mouses and converts them to the Amiga quadrature pulse format.
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

		TITLE	"YAMI - Yet Another Mouse Interface"
		PROCESSOR 16f84
		RADIX	dec

		CONFIG	FOSC = XT
		CONFIG	WDTE = ON
		CONFIG	CP = OFF
		CONFIG	PWRTE = ON

		INCLUDE "yami-version.inc"

		ORG     0x2100
		de      0x03                    ;0x03 = Amiga + Mouse Wheel support

		ORG     0x213E
		de      VER,REV                 ;Version and Revision

		END

;****************************************************************