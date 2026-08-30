import { run } from "uebersicht";

// Poll every 2s: armed when the NOPASSWD sudoers file exists.
export const command =
  "test -f /etc/sudoers.d/sudo-nopasswd && echo on || echo off";

export const refreshFrequency = 2000;

export const className = `
  top: 20px;
  left: 18px;
  width: 155px;
  height: 155px;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", sans-serif;
  border-radius: 24px;
  overflow: hidden;
  -webkit-user-select: none;
  cursor: pointer;
  box-shadow: 0 10px 30px rgba(0,0,0,0.30), inset 0 0 0 0.5px rgba(255,255,255,0.10);

  .card {
    box-sizing: border-box;
    width: 100%;
    height: 100%;
    padding: 16px 16px 15px;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    -webkit-backdrop-filter: blur(22px);
    backdrop-filter: blur(22px);
    transition: background 0.45s ease;
  }
  .card.off { background: rgba(28,28,30,0.55); }
  .card.on  { background: rgba(58,20,20,0.62); }

  .top { display: flex; align-items: center; justify-content: space-between; }

  .dot {
    width: 12px; height: 12px; border-radius: 50%;
    transition: background 0.35s ease, box-shadow 0.35s ease;
  }
  .dot.off { background: #34c759; box-shadow: 0 0 9px rgba(52,199,89,0.9); }
  .dot.on  { background: #ff453a; box-shadow: 0 0 9px rgba(255,69,58,0.95); }

  .glyph { font-size: 15px; opacity: 0.85; }

  .label {
    font-size: 16px; font-weight: 600; letter-spacing: -0.25px;
    color: #fff; margin-bottom: 3px;
  }
  .label.off { color: #eafff0; }
  .label.on  { color: #ffdad6; }

  .sub {
    font-size: 11px; font-weight: 400; line-height: 1.35;
    color: rgba(255,255,255,0.66);
  }
`;

export const render = ({ output }) => {
  const on = String(output).trim() === "on";
  const s = on ? "on" : "off";
  // The launcher app opens a terminal for the password prompt; the widget
  // just reflects state and triggers that flow.
  const toggle = () => run('open -a "Sudo Toggle"');

  return (
    <div className={`card ${s}`} onClick={toggle}>
      <div className="top">
        <span className="glyph">{on ? "🔓" : "🔒"}</span>
        <span className={`dot ${s}`} />
      </div>
      <div>
        <div className={`label ${s}`}>{on ? "Sudo Armed" : "Sudo Locked"}</div>
        <div className="sub">
          {on
            ? "Passwordless root is on. Click to lock."
            : "Root access off. Click to arm."}
        </div>
      </div>
    </div>
  );
};
