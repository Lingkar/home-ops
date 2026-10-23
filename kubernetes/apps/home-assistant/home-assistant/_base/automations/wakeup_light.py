from datetime import datetime, timedelta, time
from zoneinfo import ZoneInfo

LIGHTS = [
    "light.bedroom_light_main",
    "light.bedroom_light_bed",
]

ALARM_SENSOR = "sensor.fen_next_alarm"
ENABLE_SWITCH = "input_boolean.wakeup_light"

RAMP_MINUTES_HELPER = "input_number.wakeup_ramp_minutes"
INTERVAL_HELPER = "input_number.wakeup_interval_seconds"
BRIGHTNESS_START_HELPER = "input_number.wakeup_brightness_start"
BRIGHTNESS_MID_HELPER = "input_number.wakeup_brightness_mid"
BRIGHTNESS_END_HELPER = "input_number.wakeup_brightness_end"
SPLIT_HELPER = "input_number.wakeup_split_percent"
KELVIN_START_HELPER = "input_number.wakeup_kelvin_start"
KELVIN_MID_HELPER = "input_number.wakeup_kelvin_mid"
KELVIN_END_HELPER = "input_number.wakeup_kelvin_end"
PREVIEW_PROGRESS_HELPER = "input_number.wakeup_preview_progress"
PREVIEW_APPLY_BUTTON = "input_button.wakeup_preview_apply"
PREVIEW_START_BUTTON = "input_button.wakeup_preview_start"
PREVIEW_MID_BUTTON = "input_button.wakeup_preview_mid"
PREVIEW_END_BUTTON = "input_button.wakeup_preview_end"

DEFAULT_RAMP_MINUTES = 30
DEFAULT_INTERVAL_SEC = 60
DEFAULT_BRIGHTNESS_START = 1
DEFAULT_BRIGHTNESS_MID = 32
DEFAULT_BRIGHTNESS_END = 255
DEFAULT_SPLIT_PCT = 50
DEFAULT_KELVIN_START = 2200
DEFAULT_KELVIN_MID = 2400
DEFAULT_KELVIN_END = 2700

MIN_BRIGHTNESS = 1
MAX_BRIGHTNESS = 255
MIN_KELVIN = 2200
MAX_KELVIN = 6500

ALARM_WINDOW_START = time(4, 0)
ALARM_WINDOW_END = time(9, 30)

_TZ = ZoneInfo("Europe/Amsterdam")
_ramping = False

PREVIEW_WATCH = [
    RAMP_MINUTES_HELPER,
    BRIGHTNESS_START_HELPER,
    BRIGHTNESS_MID_HELPER,
    BRIGHTNESS_END_HELPER,
    SPLIT_HELPER,
    KELVIN_START_HELPER,
    KELVIN_MID_HELPER,
    KELVIN_END_HELPER,
    PREVIEW_PROGRESS_HELPER,
]

state.persist("pyscript.wakeup_preview_brightness", str(DEFAULT_BRIGHTNESS_START))
state.persist("pyscript.wakeup_preview_kelvin", str(DEFAULT_KELVIN_START))
state.persist("pyscript.wakeup_ramp_progress", "idle")
state.set("pyscript.wakeup_ramp_progress", "idle")

task.unique("wakeup_ramp")


def _clamp(value, low, high):
    return max(low, min(high, value))


def _number(entity, default, low=None, high=None):
    try:
        value = float(state.get(entity))
    except (NameError, TypeError, ValueError):
        return default
    if low is not None:
        value = max(low, value)
    if high is not None:
        value = min(high, value)
    return value


def _integer(entity, default, low, high):
    return int(round(_number(entity, default, low, high)))


def _ramp_minutes():
    return _number(RAMP_MINUTES_HELPER, DEFAULT_RAMP_MINUTES, 1, 120)


def _interval_seconds():
    return _integer(INTERVAL_HELPER, DEFAULT_INTERVAL_SEC, 5, 300)


def _split():
    return _number(SPLIT_HELPER, DEFAULT_SPLIT_PCT, 5, 95) / 100.0


def _segment(progress, split, start, middle, end):
    if progress <= split:
        fraction = progress / split
        return start + (middle - start) * fraction
    fraction = (progress - split) / (1.0 - split)
    return middle + (end - middle) * fraction


def _curve(progress):
    split = _split()
    brightness_start = _integer(
        BRIGHTNESS_START_HELPER, DEFAULT_BRIGHTNESS_START, MIN_BRIGHTNESS, MAX_BRIGHTNESS
    )
    brightness_mid = _integer(
        BRIGHTNESS_MID_HELPER, DEFAULT_BRIGHTNESS_MID, MIN_BRIGHTNESS, MAX_BRIGHTNESS
    )
    brightness_end = _integer(
        BRIGHTNESS_END_HELPER, DEFAULT_BRIGHTNESS_END, MIN_BRIGHTNESS, MAX_BRIGHTNESS
    )
    kelvin_start = _integer(KELVIN_START_HELPER, DEFAULT_KELVIN_START, MIN_KELVIN, MAX_KELVIN)
    kelvin_mid = _integer(KELVIN_MID_HELPER, DEFAULT_KELVIN_MID, MIN_KELVIN, MAX_KELVIN)
    kelvin_end = _integer(KELVIN_END_HELPER, DEFAULT_KELVIN_END, MIN_KELVIN, MAX_KELVIN)

    progress = _clamp(progress, 0.0, 1.0)
    brightness = _segment(progress, split, brightness_start, brightness_mid, brightness_end)
    kelvin = _segment(progress, split, kelvin_start, kelvin_mid, kelvin_end)

    brightness = int(round(_clamp(brightness, MIN_BRIGHTNESS, MAX_BRIGHTNESS)))
    kelvin = int(round(_clamp(kelvin, MIN_KELVIN, MAX_KELVIN)))
    return brightness, kelvin


def _preview_progress():
    return _number(PREVIEW_PROGRESS_HELPER, 0, 0, 100) / 100.0


def _is_enabled():
    if not state.exist(ENABLE_SWITCH):
        return False
    value = str(state.get(ENABLE_SWITCH)).lower()
    return value not in ("off", "false", "0", "unavailable", "unknown")


def _next_alarm():
    if not state.exist(ALARM_SENSOR):
        return None
    raw = state.get(ALARM_SENSOR)
    if not raw:
        return None
    try:
        alarm = datetime.fromisoformat(str(raw)).astimezone(_TZ)
    except (TypeError, ValueError):
        return None
    if not (ALARM_WINDOW_START <= alarm.time() < ALARM_WINDOW_END):
        return None
    return alarm


def _apply(progress, transition):
    brightness, kelvin = _curve(progress)
    for entity in LIGHTS:
        try:
            light.turn_on(
                entity_id=entity,
                brightness=brightness,
                color_temp_kelvin=kelvin,
                transition=transition,
            )
        except Exception as exc:
            log.warning(f"Wake-up light: failed to set {entity}: {exc}")
    return brightness, kelvin


def _attributes(progress, brightness, kelvin):
    return {
        "kelvin": kelvin,
        "brightness_pct": round(brightness / MAX_BRIGHTNESS * 100, 1),
        "progress_pct": round(progress * 100, 1),
        "minutes_before_alarm": round((1.0 - progress) * _ramp_minutes(), 1),
    }


def _publish_preview(progress):
    progress = _clamp(progress, 0.0, 1.0)
    brightness, kelvin = _curve(progress)
    state.set(
        "pyscript.wakeup_preview_brightness",
        str(brightness),
        new_attributes=_attributes(progress, brightness, kelvin),
    )
    state.set(
        "pyscript.wakeup_preview_kelvin",
        str(kelvin),
        new_attributes={
            "brightness": brightness,
            "progress_pct": round(progress * 100, 1),
        },
    )


def _publish_ramp(progress, brightness, kelvin):
    state.set(
        "pyscript.wakeup_ramp_progress",
        f"{round(progress * 100, 1)}%",
        new_attributes=_attributes(progress, brightness, kelvin),
    )


def _preview_jump(progress):
    progress = _clamp(progress, 0.0, 1.0)
    percent = int(round(progress * 100))
    if state.exist(PREVIEW_PROGRESS_HELPER):
        try:
            input_number.set_value(entity_id=PREVIEW_PROGRESS_HELPER, value=percent)
        except Exception as exc:
            log.warning(f"Wake-up light: failed to update preview slider: {exc}")
    progress = percent / 100.0
    _publish_preview(progress)
    brightness, kelvin = _apply(progress, 1)
    log.info(
        f"Wake-up preview at {percent}%: brightness={brightness}, kelvin={kelvin}"
    )


def _tick():
    global _ramping

    if not _is_enabled():
        _ramping = False
        return

    alarm = _next_alarm()
    if alarm is None:
        _ramping = False
        return

    now = datetime.now(_TZ)
    interval = _interval_seconds()

    if now >= alarm:
        if _ramping:
            _ramping = False
            brightness, kelvin = _apply(1.0, 1)
            _publish_ramp(1.0, brightness, kelvin)
        return

    ramp_start = alarm - timedelta(minutes=_ramp_minutes())
    if now < ramp_start:
        _ramping = False
        return

    duration = (alarm - ramp_start).total_seconds()
    if duration <= 0:
        return

    progress = (now - ramp_start).total_seconds() / duration
    _ramping = True
    brightness, kelvin = _apply(progress, interval)
    _publish_ramp(progress, brightness, kelvin)
    log.debug(
        f"Wake-up ramp progress={round(progress, 3)}, "
        f"brightness={brightness}, kelvin={kelvin}"
    )


@time_trigger("startup")
def wakeup_ramp(**kwargs):
    task.unique("wakeup_ramp")
    while True:
        try:
            _tick()
        except Exception as exc:
            log.error(f"Wake-up light tick failed: {exc}")
        task.sleep(_interval_seconds())


@time_trigger("startup")
@state_trigger(*PREVIEW_WATCH)
def update_preview(**kwargs):
    _publish_preview(_preview_progress())


@state_trigger(f"{PREVIEW_APPLY_BUTTON}.old != None")
def preview_apply(**kwargs):
    _preview_jump(_preview_progress())


@state_trigger(f"{PREVIEW_START_BUTTON}.old != None")
def preview_start(**kwargs):
    _preview_jump(0.0)


@state_trigger(f"{PREVIEW_MID_BUTTON}.old != None")
def preview_mid(**kwargs):
    _preview_jump(_split())


@state_trigger(f"{PREVIEW_END_BUTTON}.old != None")
def preview_end(**kwargs):
    _preview_jump(1.0)
