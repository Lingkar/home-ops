
from datetime import datetime, timedelta, time
from zoneinfo import ZoneInfo

LIGHTS = [
    "light.bedroom_light_main",
    "light.bedroom_light_bed",
]

ALARM_SENSOR        = "sensor.fen_next_alarm"
ENABLE_SWITCH       = "input_boolean.wakeup_light"   # kill switch
RAMP_BEFORE_MINUTES = 30
MIN_BRIGHTNESS_PCT  = 2
MAX_BRIGHTNESS_PCT  = 100

START_KELVIN        = 2200
END_KELVIN          = 3800
RAMP_INTERVAL_SEC   = 60
ALARM_WINDOW_START  = time(4, 0)
ALARM_WINDOW_END    = time(9, 30)

_TZ = ZoneInfo("Europe/Amsterdam")


@time_trigger("once(now)", "cron(* * * * *)")
def wakeup_ramp(**kwargs):
    task.unique("wakeup_ramp")

    if ENABLE_SWITCH and (
        not state.exist(ENABLE_SWITCH)
        or state.get(ENABLE_SWITCH).lower() in ("off", "false", "0")
    ):
        log.debug("Wake-up light functionality turned off")
        return

    raw = state.get(ALARM_SENSOR)
    if not raw:
        return

    try:
        alarm = datetime.fromisoformat(raw).astimezone(_TZ)
    except ValueError:
        return

    now = datetime.now(_TZ)
    alarm_time = alarm.time()

    if not (ALARM_WINDOW_START <= alarm_time < ALARM_WINDOW_END):
        log.debug("Alarm outside morning window")
        return

    ramp_start = alarm - timedelta(minutes=RAMP_BEFORE_MINUTES)

    if now >= alarm:
        log.debug("Max reached")
        return

    if now < ramp_start:
        log.debug("Not yet ramping")
        return

    progress = (now - ramp_start) / (alarm - ramp_start)

    brightness = (
        MIN_BRIGHTNESS_PCT
        + (MAX_BRIGHTNESS_PCT - MIN_BRIGHTNESS_PCT) * progress
    )
    kelvin = START_KELVIN + int(
        (END_KELVIN - START_KELVIN) * progress
    )

    light.turn_on(
        entity_id=LIGHTS,
        brightness_pct=brightness,
        color_temp_kelvin=kelvin,
    )

    log.debug(
        f"progress: {progress}, brightness: {brightness}, kelvin: {kelvin}"
    )
