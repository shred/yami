/*********************************************************************
**                                                                  **
**        yamiCX     -- YAMI Commodity to convert wheel moves       **
**                                                                  **
*********************************************************************/
/*
**        (C) 1999 by Richard Koerber -- All Rights Reserved
**
**  This program is free software: you can redistribute it and/or modify
**  it under the terms of the GNU General Public License as published by
**  the Free Software Foundation, either version 3 of the License, or
**  (at your option) any later version.
**
**  This program is distributed in the hope that it will be useful,
**  but WITHOUT ANY WARRANTY; without even the implied warranty of
**  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**  GNU General Public License for more details.
**
**  You should have received a copy of the GNU General Public License
**  along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

/*
    Use SAS/C! Compile command:
sc yamiCX.c LINK PNAME=yamiCX CPU=68000 NOSTACKCHECK PARM=R DATA=NEAR STRIPDBG GST=INCLUDE:all.gst STRMER OPT

*/

#include <stdio.h>
#include <string.h>
#include <pragmas/exec_pragmas.h>
#include <pragmas/dos_pragmas.h>
#include <pragmas/icon_pragmas.h>
#include <pragmas/commodities_pragmas.h>
#include <clib/alib_protos.h>
#include <clib/exec_protos.h>
#include <clib/dos_protos.h>
#include <clib/icon_protos.h>
#include <clib/intuition_protos.h>
#include <clib/commodities_protos.h>
#include <exec/io.h>
#include <exec/memory.h>
#include <exec/ports.h>
#include <libraries/dos.h>
#include <libraries/commodities.h>
#include <workbench/workbench.h>
#include <dos/stdio.h>
#include <dos/dos.h>
#include <dos/rdargs.h>
#include <devices/gameport.h>
#include <devices/inputevent.h>

#define IECLASS_MOUSEWHEEL (0x16)
#define IECLASS_WHEELMOVE  (0x7F)
#define MW_WHEEL_UP_KEY (0x7A)
#define MW_WHEEL_DOWN_KEY (0x7B)


#define VERSIONSTR "1.3"
#define VERSIONDATE "2.1.2001"

extern struct Library *DOSBase;
struct Library *CxBase;

char VerStr[] = "\0$VER: yamiCX "VERSIONSTR" ("VERSIONDATE")";

struct Global {
  BYTE  CxPri;                          // CX priority
  BYTE  Debug;
  BOOL  NoWheel;
  BOOL  NoKeys;
  BOOL  NoMoves;
} Global;

BOOL active = TRUE;                     // TRUE: CX is active, FALSE: CX is disactive
BOOL midButton = FALSE;


/**
 * Allocate the joystick port as mouse. Will fail if the port
 * is already allocated.
 *
 * @param gameio      IOStdReq of the gameport unit 1
 * @return  TRUE:successfully allocated
 */
static BOOL allocMouse(struct IOStdReq *gameio) {
  BOOL success = FALSE;
  BYTE current_type = 0;
  BYTE new_type = GPCT_MOUSE;

  // begin critical section
  // we need to be sure that between the time we check that the controller
  // is available and the time we allocate it, no one else steals it.
  Forbid();

  gameio->io_Command = GPD_ASKCTYPE;
  gameio->io_Flags   = IOF_QUICK;
  gameio->io_Data    = (APTR)&current_type;
  gameio->io_Length  = sizeof(BYTE);
  DoIO((struct IORequest *)gameio);

  // If no one is using the joy port, allocate it */
  if(current_type == GPCT_NOCONTROLLER) {
    gameio->io_Command = GPD_SETCTYPE;
    gameio->io_Flags   = IOF_QUICK;
    gameio->io_Data    = (APTR)&new_type;
    gameio->io_Length  = sizeof(BYTE);
    DoIO((struct IORequest *)gameio);
    success = TRUE;
  }

  Permit();
  return(success);
}

/**
 * Free the joystick port. It must be allocated by us before!
 *
 * @param gameio      IOStdReq of the gameport unit 1
 */
static void freeMouse(struct IOStdReq *gameio) {
  BYTE free_type = GPCT_NOCONTROLLER;

  gameio->io_Command = GPD_SETCTYPE;
  gameio->io_Flags   = IOF_QUICK;
  gameio->io_Data    = (APTR)&free_type;
  gameio->io_Length  = sizeof(BYTE);
  DoIO((struct IORequest *)gameio);
}

/**
 * Flush the joystick port, to bring it into a definite state.
 *
 * @param gameio      IOStdReq of the gameport unit 1
 */
static void flushMouse(struct IOStdReq *gameio) {
  gameio->io_Command = CMD_CLEAR;
  gameio->io_Flags   = IOF_QUICK;
  gameio->io_Data    = NULL;
  gameio->io_Length  = 0;
  DoIO((struct IORequest *)gameio);
}

/**
 * Set the trigger events
 *
 * @param gameio      IOStdReq of the gameport unit 1
 */
static void setMouseTrigger(struct IOStdReq *gameio) {
  struct GamePortTrigger gpt;

  gpt.gpt_Keys    = GPTF_UPKEYS | GPTF_DOWNKEYS;            // transfer keypress and release
  gpt.gpt_XDelta  = 1;                                      // trigger on all moves
  gpt.gpt_YDelta  = 1;
  gpt.gpt_Timeout = 1000;                                   // some timeout, in ticks

  gameio->io_Command = GPD_SETTRIGGER;
  gameio->io_Flags   = IOF_QUICK;
  gameio->io_Data    = (APTR)&gpt;
  gameio->io_Length  = sizeof(struct GamePortTrigger);
  DoIO((struct IORequest *)gameio);
}

static void showEvent(struct InputEvent *ievent) {
  Printf("------\n");
  Printf("  ie_NextEvent: 0x%08lx\n",ievent->ie_NextEvent);
  Printf("  ie_Class: %ld    ie_SubClass: %ld\n",ievent->ie_Class,ievent->ie_SubClass);
  Printf("  ie_Code: %ld    ie_Qualifier: %ld\n",ievent->ie_Code,ievent->ie_Qualifier);
  Printf("  ie_X: %ld    ie_Y: %ld\n",ievent->ie_X,ievent->ie_Y);
  Printf("  ie_TimeStamp: %lds, %ldµ\n",ievent->ie_TimeStamp.tv_secs,ievent->ie_TimeStamp.tv_micro);
}

/**
 * Process a wheel mouse event
 *
 * @param ievent      IEvent message received
 */
static void processMsg(struct InputEvent *ievent) {
  struct InputEvent send;

  //--- Check the mouse button ---
  switch(ievent->ie_Code) {
    case IECODE_LBUTTON:
      if(Global.Debug>0) Printf("Mouse wheel pressed\n");
      ievent->ie_Class = IECLASS_RAWMOUSE;
      ievent->ie_Code  = IECODE_MBUTTON;
      ievent->ie_Qualifier = IEQUALIFIER_MIDBUTTON;
      ievent->ie_position.ie_xy.ie_x = 0;
      ievent->ie_position.ie_xy.ie_y = 0;
      midButton = TRUE;
      if(Global.Debug>1) showEvent(ievent);
      AddIEvents(ievent);
      break;

    case IECODE_LBUTTON | IECODE_UP_PREFIX:
      if(Global.Debug>0) Printf("Mouse wheel released\n");
      ievent->ie_Class = IECLASS_RAWMOUSE;
      ievent->ie_Code  = IECODE_MBUTTON | IECODE_UP_PREFIX;
      ievent->ie_position.ie_xy.ie_x = 0;
      ievent->ie_position.ie_xy.ie_y = 0;
      midButton = FALSE;
      if(Global.Debug>1) showEvent(ievent);
      AddIEvents(ievent);
      break;

    case IECODE_NOBUTTON: {
        WORD moveX = ievent->ie_X;
        WORD moveY = ievent->ie_Y;
        WORD cnt;

        if(Global.Debug>0) Printf("moveX=%ld, moveY=%ld\n",moveX,moveY);
        //--- Send our WHEELMOVE event ---
        if(!Global.NoWheel && (moveX!=0 || moveY!=0)) {
          send.ie_NextEvent = NULL;
          send.ie_TimeStamp = ievent->ie_TimeStamp;
          send.ie_Class     = IECLASS_WHEELMOVE;
          send.ie_SubClass  = 0;
          send.ie_Code      = 0;
          send.ie_Qualifier = (midButton ? IEQUALIFIER_MIDBUTTON : 0);
          send.ie_X         = moveX;
          send.ie_Y         = moveY;
          if(Global.Debug>1) showEvent(&send);
          AddIEvents(&send);
        }

        //--- Send compatibility events (vertical only) ---
        if((!Global.NoKeys) && (!Global.NoMoves) && moveY!=0) {
          send.ie_X = 0;
          send.ie_Y = 0;
          send.ie_Qualifier = (midButton ? IEQUALIFIER_MIDBUTTON : 0);
          send.ie_Code = (moveY>0 ? MW_WHEEL_DOWN_KEY : MW_WHEEL_UP_KEY);
          cnt = (moveY>0 ? moveY : -moveY);
          while(cnt--) {
            if(!Global.NoMoves) {
              send.ie_Class = IECLASS_MOUSEWHEEL;
              if(Global.Debug>1)showEvent(&send);
              AddIEvents(&send);
            }
            if(!Global.NoKeys) {
              send.ie_Class = IECLASS_RAWKEY;
              if(Global.Debug>1)showEvent(&send);
              AddIEvents(&send);
            }
            send.ie_TimeStamp.tv_secs = 0;
            send.ie_TimeStamp.tv_micro = 0;
          }
        }

        break;
      }

    default:
      break;
  }
}

/*------------------------------------------------------------------**
**  MainLoop      -- Process all events
*/
void MainLoop (void) {
  struct MsgPort *cxport, *gameport;
  struct Message *cxmsg;
  struct IOStdReq *gameio;
  ULONG gotmask, waitmask;
  struct NewBroker cxnewbroker = {
    NB_VERSION,
    "yamiCX",
    "yamiCX V"VERSIONSTR" (C)1999-2000 Richard Körber",
    "YAMI wheel driver commodity",
    0,  // unique
    0,
    0,
    NULL,
    0
  };
  CxObj *cxbroker;
  struct InputEvent ievent;

  //-- Create the commodity broker --
  cxport = CreateMsgPort();
  if(cxport) {
    cxnewbroker.nb_Port = cxport;
    cxnewbroker.nb_Pri  = Global.CxPri;
    cxbroker = CxBroker(&cxnewbroker,NULL);
    if(cxbroker) {
      ActivateCxObj(cxbroker,1L);

      gameport = CreateMsgPort();                           // Create a message port
      if(gameport)
      {
        gameio = (struct IOStdReq *)CreateIORequest(gameport,sizeof(struct IOStdReq));
        if(gameio)
        {
          if(!OpenDevice("gameport.device",1,(struct IORequest *)gameio,0L))    // Open gameport, unit 1 (=joyport)
          {
            waitmask =   (1<<gameport->mp_SigBit)
                       | (1<<cxport->mp_SigBit);

            active = allocMouse(gameio);
            if(active) {
              setMouseTrigger(gameio);
              flushMouse(gameio);
            }else {
              ActivateCxObj(cxbroker,0L);                       // Disactivate the CX because port is allocated
            }

            //--- Deploy first event request ---
            gameio->io_Command = GPD_READEVENT;
            gameio->io_Flags   = 0;
            gameio->io_Data    = (APTR)&ievent;
            gameio->io_Length  = sizeof(struct InputEvent);
            SendIO((struct IORequest *)gameio);

            for(;;) {
              //--- Check input device ---
              if(GetMsg(gameport)) {
                processMsg(&ievent);                            // Process this message
                gameio->io_Command = GPD_READEVENT;
                gameio->io_Flags   = 0;
                gameio->io_Data    = (APTR)&ievent;
                gameio->io_Length  = sizeof(struct InputEvent);
                SendIO((struct IORequest *)gameio);
              }

              //--- Check commodity ---
              if(cxmsg = GetMsg(cxport)) {
                ULONG msgtype = CxMsgType((CxMsg *)cxmsg);
                ULONG msgid   = CxMsgID  ((CxMsg *)cxmsg);
                LONG old;

                if(msgtype == CXM_COMMAND) {
                  switch(msgid) {
                    case CXCMD_DISABLE:                         //-- Disable yamiCX --
                      old = ActivateCxObj(cxbroker,0L);
                      if(old) {                                 //  it was really activated before
                        active = FALSE;                         //  so turn it off
                        AbortIO((struct IORequest *)gameio);    // abort the current request
                        WaitIO((struct IORequest *)gameio);
                        freeMouse(gameio);                      // Free the mouse port
                      }
                      break;

                    case CXCMD_ENABLE:                          //-- Enable yamiCX --
                      old = ActivateCxObj(cxbroker,1L);
                      if(!old) {                                //  it was really shut down before
                        active = allocMouse(gameio);            // Allocate the joystick port
                        if(active) {
                          setMouseTrigger(gameio);
                          flushMouse(gameio);
                          gameio->io_Command = GPD_READEVENT;   // Start to send events again
                          gameio->io_Flags   = 0;
                          gameio->io_Data    = (APTR)&ievent;
                          gameio->io_Length  = sizeof(struct InputEvent);
                          SendIO((struct IORequest *)gameio);
                        }else {
                          ActivateCxObj(cxbroker,0L);           // Disactivate the CX because port is allocated
                        }
                      }
                      break;

                    case CXCMD_KILL:                            //-- Kill CX --
                      Signal(FindTask(NULL),SIGBREAKF_CTRL_C);  //  just send ourself a <CTRL><C>
                      break;
                  }
                }
                ReplyMsg(cxmsg);
                continue;
              }

              //-- Check <CTRL><C> --
              gotmask = Wait(waitmask|SIGBREAKF_CTRL_C);
              if(gotmask & SIGBREAKF_CTRL_C) break;
            }

            AbortIO((struct IORequest *)gameio);                // Abort current request
            WaitIO((struct IORequest *)gameio);                 // Wait until finishe
            freeMouse(gameio);                                  // Free the mouse port
            CloseDevice((struct IORequest *)gameio);            // Close the gameport
          }
          DeleteIORequest(gameio);                              // Release the IORequest
        }
        DeleteMsgPort(gameport);                                // and the message port
      }
      ActivateCxObj(cxbroker,0L);
      DeleteCxObjAll(cxbroker);
    }
    while(cxmsg=GetMsg(cxport)) ReplyMsg(cxmsg);                // Flush all CX messages
    DeleteMsgPort(cxport);
  }
}

//> ParseParam
/*------------------------------------------------------------------**
**  ParseParam    -- Parses the parameters
*/
LONG ParseParam(int argc, char **argv) {
  //-- Initialize the global structure --
  Global.CxPri     = 0;
  Global.Debug     = 0;
  Global.NoWheel   = FALSE;
  Global.NoKeys    = FALSE;
  Global.NoMoves   = FALSE;

  if(argc==0)  {

    //-- Start from Workbench --
    struct Library *IconBase = OpenLibrary("icon.library",36L);
    struct WBArg *wbarg;
    struct DiskObject *dobj;
    char   path[256];
    char   *type;
    char   **tools;

    if(IconBase) {
      wbarg = ((struct WBStartup *)argv)->sm_ArgList;
      NameFromLock(wbarg->wa_Lock, path, 256);
      AddPart(path, wbarg->wa_Name, 256);
      dobj = GetDiskObject(path);                               // Read the icon
      if(dobj) {
        tools = dobj->do_ToolTypes;

        type = FindToolType(tools,"CX_PRIORITY");               // CX-Pri
        if(type) {
          LONG val;
          StrToLong(type,&val);
          Global.CxPri = val;
        }

        type = FindToolType(tools,"NOWHEEL");
        if(type) {
          Global.NoWheel = TRUE;
        }
        type = FindToolType(tools,"NOKEYS");
        if(type) {
          Global.NoKeys = TRUE;
        }
        type = FindToolType(tools,"NOMOVES");
        if(type) {
          Global.NoMoves = TRUE;
        }

        FreeDiskObject(dobj);
        CloseLibrary(IconBase);
      }
    }
    return(1);

  }else {
    //-- Start from Shell --

    struct RDArgs *args;
    static char template[]   = "CXPRI/K/N,NOWHEEL/S,NOKEYS/S,NOMOVES/S,DEBUG/K/N";
    struct Parameter {
      LONG *cxpri;
      LONG nowheel;
      LONG nokeys;
      LONG nomoves;
      LONG *debug;
    }param = {NULL};

    if(args = (struct RDArgs *)ReadArgs(template,(LONG *)&param,NULL)) {
      if(param.cxpri) {
        Global.CxPri = *(param.cxpri);
      }
      if(param.nowheel) {
        Global.NoWheel = TRUE;
      }
      if(param.nokeys) {
        Global.NoKeys = TRUE;
      }
      if(param.nomoves) {
        Global.NoMoves = TRUE;
      }
      if(param.debug) {
        Global.Debug = *(param.debug);
      }
      FreeArgs(args);
      return(1);
    }
  }
  return(0);
}
//<
//> main()
/*------------------------------------------------------------*
*   main()          M A I N   P R O G R A M                   *
*/
int main(int argc, char **argv) {

  CxBase = OpenLibrary("commodities.library",36L);
  if(!CxBase) return(5);

  //-- Read all parameters --
  if(!ParseParam(argc,argv)) return(10);

  //-- Main Part --
  MainLoop();

  //-- Shutdown --
  CloseLibrary(CxBase);

  return(0);
}
//<

/********************************************************************/

