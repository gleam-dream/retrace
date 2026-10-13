// Scoped default styles. Applications may override these selectors in their CSS.
export const css = `:where(.retrace-viewer) *{
  box-sizing: border-box;
}
.retrace-viewer{
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  color: #202e28;
  background: #f7f8f5;
  font-synthesis: none;
}
:where(.retrace-viewer) button,
:where(.retrace-viewer) input,
:where(.retrace-viewer) select{
  font: inherit;
}
:where(.retrace-viewer) button{
  min-height: 40px;
  cursor: pointer;
  border: 1px solid #d7dfd7;
  border-radius: 8px;
  background: white;
  color: #293e32;
  padding: 8px 13px;
}
:where(.retrace-viewer) button:hover{
  background: #edf3ed;
}
:where(.retrace-viewer) button:disabled{
  opacity: 0.45;
  cursor: default;
}
:where(.retrace-viewer) button:focus-visible,
:where(.retrace-viewer) input:focus-visible,
:where(.retrace-viewer) select:focus-visible{
  outline: 3px solid #4f8c70;
  outline-offset: 3px;
}
:where(.retrace-viewer) input{
  caret-color: #174d3c;
}
:where(.retrace-viewer) ::selection{
  background: #c7dfd0;
}
:where(.retrace-viewer) [hidden]{
  display: none !important;
}
:where(.retrace-viewer) .topbar{
  height: 64px;
  display: flex;
  align-items: center;
  gap: 24px;
  padding: 0 28px;
  background: #fff;
  border-bottom: 1px solid #dfe5de;
}
:where(.retrace-viewer) .topbar strong{
  font-size: 22px;
  letter-spacing: -0.03em;
}
:where(.retrace-viewer) .topbar > span{
  font-size: 13px;
  color: #607064;
}
:where(.retrace-viewer) .topbar .local{
  margin-left: auto;
  font-size: 12px;
}
:where(.retrace-viewer) .layout{
  display: grid;
  grid-template-columns: 240px 1fr;
  height: calc(100dvh - 64px);
}
:where(.retrace-viewer) .sessions{
  background: #fff;
  border-right: 1px solid #dfe5de;
  padding: 28px 20px;
  min-width: 0;
  overflow: auto;
  scrollbar-color: #bac9bd #fff;
}
:where(.retrace-viewer) .sessions h1{
  font-size: 18px;
  margin: 0 0 24px;
}
:where(.retrace-viewer) .search label{
  font-size: 12px;
  color: #55695b;
  display: block;
  margin-bottom: 8px;
}
:where(.retrace-viewer) .search > div{
  display: flex;
  gap: 6px;
}
:where(.retrace-viewer) .search input{
  min-width: 0;
  width: 100%;
  border: 1px solid #c8d4c9;
  border-radius: 8px;
  background: #fafcf9;
  padding: 8px 10px;
  font-size: 13px;
}
:where(.retrace-viewer) .search-status{
  font-size: 12px;
  color: #627167;
  line-height: 1.5;
  margin: 16px 0;
}
:where(.retrace-viewer) .session-list{
  display: flex;
  flex-direction: column;
  gap: 6px;
}
:where(.retrace-viewer) .session-row{
  text-align: left;
  border-color: transparent;
  background: transparent;
  padding: 13px 10px;
  min-width: 0;
}
:where(.retrace-viewer) .session-row[aria-pressed="true"]{
  background: #eaf1e9;
  border-color: #c8d7c9;
}
:where(.retrace-viewer) .session-row strong{
  display: block;
  font-size: 14px;
}
:where(.retrace-viewer) .session-row span{
  display: block;
  font-size: 12px;
  color: #576d5d;
  margin: 7px 0;
}
:where(.retrace-viewer) .session-row small{
  display: block;
  font-size: 10px;
  font-family: ui-monospace, monospace;
  overflow-wrap: anywhere;
  color: #65756b;
}
:where(.retrace-viewer) .workspace{
  min-width: 0;
  min-height: 0;
  display: flex;
  flex-direction: column;
}
:where(.retrace-viewer) .session-heading{
  padding: 22px 28px 18px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  background: #fafbf8;
  border-bottom: 1px solid #e1e7de;
}
:where(.retrace-viewer) .session-heading h2{
  font-size: 19px;
  margin: 0 0 8px;
  font-weight: 600;
}
:where(.retrace-viewer) .identity{
  font-size: 11px;
  color: #627266;
  margin: 0;
  overflow-wrap: anywhere;
  line-height: 1.5;
}
:where(.retrace-viewer) .reload{
  font-size: 12px;
  flex-shrink: 0;
}
:where(.retrace-viewer) .replay-body{
  display: grid;
  grid-template-columns: minmax(0, 1fr) 280px;
  min-height: 0;
  flex: 1;
}
:where(.retrace-viewer) .stage{
  position: relative;
  min-height: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #edf0e9;
  padding-bottom: 22px;
  overflow: hidden;
}
:where(.retrace-viewer) .stage-message{
  max-width: 370px;
  padding: 28px;
  font-size: 14px;
  line-height: 1.7;
  color: #536658;
  text-align: center;
}
:where(.retrace-viewer) .stage-message[role="alert"]{
  color: #7d3228;
}
:where(.retrace-viewer) .frame-size{
  position: relative;
  flex-shrink: 0;
}
:where(.retrace-viewer) .frame-size iframe{
  position: absolute;
  top: 0;
  left: 0;
  transform-origin: top left;
  border: 8px solid #26382d;
  box-sizing: content-box;
  background: #f5f6f2;
  pointer-events: none;
  box-shadow: 0 14px 28px #21382020;
}
:where(.retrace-viewer) .viewport-label{
  position: absolute;
  bottom: 8px;
  margin: 0;
  font-size: 11px;
  color: #526657;
  font-variant-numeric: tabular-nums;
}
:where(.retrace-viewer) .events{
  min-height: 0;
  overflow: auto;
  background: #fff;
  border-left: 1px solid #dfe5de;
  scrollbar-color: #bac9bd #fff;
}
:where(.retrace-viewer) .events header{
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 22px 20px 4px;
}
:where(.retrace-viewer) .events h3{
  font-size: 14px;
  margin: 0;
}
:where(.retrace-viewer) .count{
  font-size: 12px;
  color: #586d5e;
}
:where(.retrace-viewer) .event-hint{
  padding: 0 20px;
  font-size: 12px;
  color: #65756b;
  line-height: 1.5;
  margin-bottom: 20px;
}
:where(.retrace-viewer) .events ol{
  list-style: none;
  padding: 0;
  margin: 0;
}
:where(.retrace-viewer) .event-row{
  width: 100%;
  display: grid;
  grid-template-columns: 48px 1fr;
  column-gap: 12px;
  text-align: left;
  border: 0;
  border-radius: 0;
  padding: 16px 20px;
  background: transparent;
  border-top: 1px solid #edf0e9;
}
:where(.retrace-viewer) .event-row[aria-current="true"]{
  background: #e9f1e8;
}
:where(.retrace-viewer) .event-row time{
  font-size: 12px;
  color: #506757;
  font-variant-numeric: tabular-nums;
}
:where(.retrace-viewer) .event-row span{
  font-size: 12px;
  line-height: 1.5;
}
:where(.retrace-viewer) .event-row small{
  grid-column: 2;
  color: #596d60;
  font-size: 10px;
  margin-top: 5px;
}
:where(.retrace-viewer) .transport{
  background: #fff;
  border-top: 1px solid #dfe5de;
  padding: 18px 28px 16px;
}
:where(.retrace-viewer) .transport-controls{
  display: flex;
  gap: 8px;
  align-items: center;
}
:where(.retrace-viewer) .transport-controls button{
  font-size: 12px;
}
:where(.retrace-viewer) .transport-controls .play{
  background: #174d3c;
  border-color: #174d3c;
  color: white;
  min-width: 75px;
}
:where(.retrace-viewer) .clock{
  font-size: 13px;
  font-variant-numeric: tabular-nums;
  margin-left: 12px;
  white-space: nowrap;
}
:where(.retrace-viewer) .speed-label{
  margin-left: auto;
  font-size: 12px;
  color: #53685a;
  white-space: nowrap;
}
:where(.retrace-viewer) .speed-label select{
  border: 1px solid #d7dfd7;
  border-radius: 8px;
  margin-left: 6px;
  padding: 8px;
  background: white;
  color: #293e32;
  min-height: 40px;
}
:where(.retrace-viewer) .timeline{
  margin-top: 18px;
  position: relative;
  padding-top: 22px;
}
:where(.retrace-viewer) .markers{
  position: absolute;
  left: 8px;
  right: 8px;
  top: 0;
  height: 22px;
}
:where(.retrace-viewer) .marker{
  position: absolute;
  transform: translateX(-50%);
  top: -4px;
  width: 22px;
  min-height: 28px;
  height: 28px;
  background: transparent;
  border: 0;
  border-radius: 0;
  padding: 0;
}
:where(.retrace-viewer) .marker::after{
  content: "";
  display: block;
  width: 3px;
  height: 10px;
  background: #64836c;
  margin: auto;
}
:where(.retrace-viewer) .marker.cluster{
  font-size: 9px;
  color: #31553b;
}
:where(.retrace-viewer) .marker.cluster::after{
  height: 5px;
}
:where(.retrace-viewer) .scrubber{
  display: block;
  width: 100%;
  margin: 0;
  height: 20px;
  accent-color: #174d3c;
  cursor: pointer;
}
:where(.retrace-viewer) .timeline-caption{
  display: flex;
  justify-content: space-between;
  gap: 12px;
  font-size: 10px;
  color: #607363;
  margin-top: 10px;
}
:where(.retrace-viewer) .range-note{
  text-align: right;
}
@media (max-width: 1100px){:where(.retrace-viewer) .layout{
    grid-template-columns: 200px 1fr;
  }
:where(.retrace-viewer) .replay-body{
    grid-template-columns: minmax(0, 1fr) 220px;
  }
:where(.retrace-viewer) .session-heading{
    padding: 18px 20px;
  }
:where(.retrace-viewer) .events header{
    padding: 18px 14px 4px;
  }
:where(.retrace-viewer) .event-row{
    padding: 14px;
  }
:where(.retrace-viewer) .event-hint{
    padding: 0 14px;
  }
:where(.retrace-viewer) .transport{
    padding: 16px 20px;
  }

}
@media (max-width: 800px){:where(.retrace-viewer) .layout{
    height: auto;
    min-height: calc(100dvh - 64px);
    grid-template-columns: 1fr;
  }
:where(.retrace-viewer) .sessions{
    border-right: 0;
    border-bottom: 1px solid #dfe5de;
    padding: 18px 20px;
  }
:where(.retrace-viewer) .sessions h1{
    margin-bottom: 12px;
  }
:where(.retrace-viewer) .search{
    max-width: 420px;
  }
:where(.retrace-viewer) .session-list{
    flex-direction: row;
    overflow: auto;
  }
:where(.retrace-viewer) .session-row{
    min-width: 180px;
    max-width: 210px;
  }
:where(.retrace-viewer) .search-status{
    margin: 10px 0;
  }
:where(.retrace-viewer) .replay-body{
    grid-template-columns: minmax(0, 1fr) 220px;
    height: 660px;
    flex: none;
  }
:where(.retrace-viewer) .transport{
    position: static;
  }
:where(.retrace-viewer) .topbar{
    padding: 0 20px;
  }
:where(.retrace-viewer) .topbar .local{
    display: none;
  }

}
@media (max-width: 540px){:where(.retrace-viewer) .replay-body{
    grid-template-columns: 1fr;
    height: auto;
  }
:where(.retrace-viewer) .stage{
    height: 600px;
  }
:where(.retrace-viewer) .events{
    max-height: 210px;
    border-left: 0;
    border-top: 1px solid #dfe5de;
  }
:where(.retrace-viewer) .events header{
    padding-top: 14px;
  }
:where(.retrace-viewer) .event-hint{
    margin: 6px 0 12px;
  }
:where(.retrace-viewer) .event-row{
    grid-template-columns: 50px 1fr 25px;
    padding: 10px 20px;
  }
:where(.retrace-viewer) .event-row small{
    grid-column: 3;
  }
:where(.retrace-viewer) .transport{
    padding: 12px;
  }
:where(.retrace-viewer) .transport-controls{
    gap: 5px;
    flex-wrap: wrap;
  }
:where(.retrace-viewer) .clock{
    margin-left: auto;
    font-size: 12px;
  }
:where(.retrace-viewer) .speed-label{
    width: 100%;
    display: flex;
    justify-content: flex-end;
    align-items: center;
    font-size: 11px;
  }
:where(.retrace-viewer) .speed-label select{
    min-height: 32px;
    padding: 4px 8px;
  }
:where(.retrace-viewer) .timeline{
    margin-top: 10px;
  }
:where(.retrace-viewer) .timeline-caption{
    font-size: 9px;
  }
:where(.retrace-viewer) .session-heading{
    align-items: flex-start;
  }
:where(.retrace-viewer) .reload{
    max-width: 85px;
  }
:where(.retrace-viewer) .topbar{
    gap: 18px;
  }

}

`;
