defmodule QuakeServer.Keys do
  @moduledoc """
  FTE's key numbers (`keynum_t`), key names and modifiers, and the QuakeC key codes the
  client and menu programs use for them, as FTE's `keys.c` and `pr_clcmd.c` number,
  name and translate them.

      QuakeServer.Keys.string_to_keynum("ctrl+w")
      #=> {119, 4}
      QuakeServer.Keys.keynum_to_string(QuakeServer.Keys.keynum(:uparrow), 0)
      #=> "UPARROW"
      QuakeServer.Keys.to_qc(QuakeServer.Keys.keynum(:mouse1))
      #=> 512

  A key number below 128 is the key's ASCII code (letters lower case). A modifier is a
  bit set of `shift` (1), `alt` (2) and `ctrl` (4); with `altbindmap` (8) set, the low
  bits name a bind map instead. `string_to_keynum/1` gives `:all` as the modifier when
  the name has no modifier prefix (every modifier state); a `std_` or `std+` prefix
  means no modifier (0).
  """

  import Bitwise

  @order ~w(scrlck capslock power pause uparrow downarrow leftarrow rightarrow lalt lctrl
    lshift ins del pgdn pgup home end f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 f13 f14 f15
    kp_home kp_uparrow kp_pgup kp_leftarrow kp_5 kp_rightarrow kp_end kp_downarrow kp_pgdn
    kp_enter kp_ins kp_del kp_slash kp_minus kp_plus kp_numlock kp_star kp_equals mouse1
    mouse2 mouse3 mouse4 mouse5 mwheeldown mwheelup joy1 joy2 joy3 joy4 joy5 joy6 joy7 joy8
    joy9 joy10 joy11 joy12 joy13 joy14 joy15 joy16 joy17 joy18 joy19 joy20 joy21 joy22 joy23
    joy24 joy25 joy26 joy27 joy28 joy29 joy30 joy31 joy32 aux1 aux2 aux3 aux4 aux5 aux6 aux7
    aux8 aux9 aux10 aux11 aux12 aux13 aux14 aux15 aux16 gp_diamond_down gp_diamond_right
    gp_diamond_left gp_diamond_up gp_view gp_guide gp_menu gp_left_stick gp_right_stick
    gp_left_shoulder gp_right_shoulder gp_dpad_up gp_dpad_down gp_dpad_left gp_dpad_right
    gp_misc1 gp_paddle1 gp_paddle2 gp_paddle3 gp_paddle4 gp_touchpad gp_left_trigger
    gp_right_trigger gp_left_thumb_up gp_left_thumb_down gp_left_thumb_left
    gp_left_thumb_right gp_right_thumb_up gp_right_thumb_down gp_right_thumb_left
    gp_right_thumb_right gp_unknown mouse6 mouse7 mouse8 mouse9 mouse10 joy_up joy_down
    joy_left joy_right lwin rwin app search volup voldown ralt rctrl rshift printscreen
    mm_browser_back mm_browser_favorites mm_browser_forward mm_browser_home
    mm_browser_refresh mm_browser_stop mm_volume_mute mm_track_next mm_track_prev
    mm_track_stop mm_track_playpause touch touchslide touchtap touchlong)a

  @numbers @order
           |> Enum.with_index(128)
           |> Map.new()
           |> Map.merge(%{tab: 9, enter: 13, escape: 27, space: 32, backspace: 127})

  @max 128 + length(@order)

  @aliases %{
    gp_a: :gp_diamond_down,
    gp_b: :gp_diamond_right,
    gp_x: :gp_diamond_left,
    gp_y: :gp_diamond_up,
    gp_back: :gp_view,
    gp_start: :gp_menu,
    gp_ps_cross: :gp_diamond_down,
    gp_ps_circle: :gp_diamond_right,
    gp_ps_square: :gp_diamond_left,
    gp_ps_triangle: :gp_diamond_up,
    shift: :lshift,
    ctrl: :lctrl,
    alt: :lalt,
    win: :lwin,
    mwheelleft: :mouse9,
    mwheelright: :mouse10
  }

  @names [
    {"TAB", :tab},
    {"ENTER", :enter},
    {"RETURN", :enter},
    {"ESCAPE", :escape},
    {"SPACE", :space},
    {"BACKSPACE", :backspace},
    {"UPARROW", :uparrow},
    {"DOWNARROW", :downarrow},
    {"LEFTARROW", :leftarrow},
    {"RIGHTARROW", :rightarrow},
    {"LALT", :lalt},
    {"RALT", :ralt},
    {"LCTRL", :lctrl},
    {"RCTRL", :rctrl},
    {"LSHIFT", :lshift},
    {"RSHIFT", :rshift},
    {"ALT", :alt},
    {"CTRL", :ctrl},
    {"SHIFT", :shift},
    {"F1", :f1},
    {"F2", :f2},
    {"F3", :f3},
    {"F4", :f4},
    {"F5", :f5},
    {"F6", :f6},
    {"F7", :f7},
    {"F8", :f8},
    {"F9", :f9},
    {"F10", :f10},
    {"F11", :f11},
    {"F12", :f12},
    {"INS", :ins},
    {"DEL", :del},
    {"PGDN", :pgdn},
    {"PGUP", :pgup},
    {"HOME", :home},
    {"END", :end},
    {"KP_HOME", :kp_home},
    {"KP_UPARROW", :kp_uparrow},
    {"KP_PGUP", :kp_pgup},
    {"KP_LEFTARROW", :kp_leftarrow},
    {"KP_5", :kp_5},
    {"KP_RIGHTARROW", :kp_rightarrow},
    {"KP_END", :kp_end},
    {"KP_DOWNARROW", :kp_downarrow},
    {"KP_PGDN", :kp_pgdn},
    {"KP_ENTER", :kp_enter},
    {"KP_INS", :kp_ins},
    {"KP_DEL", :kp_del},
    {"KP_SLASH", :kp_slash},
    {"KP_MINUS", :kp_minus},
    {"KP_PLUS", :kp_plus},
    {"KP_NUMLOCK", :kp_numlock},
    {"KP_STAR", :kp_star},
    {"KP_MULTIPLY", :kp_star},
    {"KP_EQUALS", :kp_equals},
    {"KP_0", :kp_ins},
    {"KP_1", :kp_end},
    {"KP_2", :kp_downarrow},
    {"KP_3", :kp_pgdn},
    {"KP_4", :kp_leftarrow},
    {"KP_6", :kp_rightarrow},
    {"KP_7", :kp_home},
    {"KP_8", :kp_uparrow},
    {"KP_9", :kp_pgup},
    {"KP_PERIOD", :kp_del},
    {"KP_DIVIDE", :kp_slash},
    {"NUMLOCK", :kp_numlock},
    {"MOUSE1", :mouse1},
    {"MOUSE2", :mouse2},
    {"MOUSE3", :mouse3},
    {"MOUSE4", :mouse4},
    {"MOUSE5", :mouse5},
    {"MOUSE6", :mouse6},
    {"MOUSE7", :mouse7},
    {"MOUSE8", :mouse8},
    {"MOUSE9", :mouse9},
    {"MOUSE10", :mouse10},
    {"MWHEELUP", :mwheelup},
    {"MWHEELDOWN", :mwheeldown},
    {"MWHEELLEFT", :mwheelleft},
    {"MWHEELRIGHT", :mwheelright},
    {"TOUCH", :touch},
    {"TOUCHSLIDE", :touchslide},
    {"TOUCHTAP", :touchtap},
    {"TOUCHLONG", :touchlong},
    {"LWIN", :lwin},
    {"RWIN", :rwin},
    {"WIN", :win},
    {"RCOMMAND", :rwin},
    {"LCOMMAND", :lwin},
    {"COMMAND", :win},
    {"LMETA", :lwin},
    {"RMETA", :rwin},
    {"APP", :app},
    {"MENU", :app},
    {"SEARCH", :search},
    {"POWER", :power},
    {"VOLUP", :volup},
    {"VOLDOWN", :voldown}
  ]

  @joys for n <- 1..32, do: {"JOY#{n}", :"joy#{n}"}
  @auxes for n <- 1..16, do: {"AUX#{n}", :"aux#{n}"}

  @more_names [
    {"PAUSE", :pause},
    {"PRINTSCREEN", :printscreen},
    {"CAPSLOCK", :capslock},
    {"SCROLLLOCK", :scrlck},
    {"SEMICOLON", ?;},
    {"PLUS", ?+},
    {"MINUS", ?-},
    {"APOSTROPHE", ?'},
    {"QUOTES", ?"},
    {"TILDE", ?~},
    {"BACKQUOTE", ?`},
    {"BACKSLASH", ?\\},
    {"GP_A", :gp_a},
    {"GP_B", :gp_b},
    {"GP_X", :gp_x},
    {"GP_Y", :gp_y},
    {"GP_LSHOULDER", :gp_left_shoulder},
    {"GP_RSHOULDER", :gp_right_shoulder},
    {"GP_LTRIGGER", :gp_left_trigger},
    {"GP_RTRIGGER", :gp_right_trigger},
    {"GP_VIEW", :gp_view},
    {"GP_MENU", :gp_menu},
    {"GP_LTHUMB", :gp_left_stick},
    {"GP_RTHUMB", :gp_right_stick},
    {"GP_DPAD_UP", :gp_dpad_up},
    {"GP_DPAD_DOWN", :gp_dpad_down},
    {"GP_DPAD_LEFT", :gp_dpad_left},
    {"GP_DPAD_RIGHT", :gp_dpad_right},
    {"GP_GUIDE", :gp_guide},
    {"GP_SHARE", :gp_misc1},
    {"GP_PADDLE1", :gp_paddle1},
    {"GP_PADDLE2", :gp_paddle2},
    {"GP_PADDLE3", :gp_paddle3},
    {"GP_PADDLE4", :gp_paddle4},
    {"GP_TOUCHPAD", :gp_touchpad},
    {"GP_UNKNOWN", :gp_unknown},
    {"GP_BACK", :gp_back},
    {"GP_START", :gp_start},
    {"GP_CROSS", :gp_ps_cross},
    {"GP_CIRCLE", :gp_ps_circle},
    {"GP_SQUARE", :gp_ps_square},
    {"GP_TRIANGLE", :gp_ps_triangle},
    {"GP_MIC", :gp_misc1},
    {"GP_SELECT", :gp_view},
    {"GP_SHARE", :gp_view},
    {"GP_OPTIONS", :gp_start},
    {"GP_LTHUMB_UP", :gp_left_thumb_up},
    {"GP_LTHUMB_DOWN", :gp_left_thumb_down},
    {"GP_LTHUMB_LEFT", :gp_left_thumb_left},
    {"GP_LTHUMB_RIGHT", :gp_left_thumb_right},
    {"GP_RTHUMB_UP", :gp_right_thumb_up},
    {"GP_RTHUMB_DOWN", :gp_right_thumb_down},
    {"GP_RTHUMB_LEFT", :gp_right_thumb_left},
    {"GP_RTHUMB_RIGHT", :gp_right_thumb_right},
    {"ESC", :escape},
    {"B_SPACE", :backspace},
    {"U_ARROW", :uparrow},
    {"D_ARROW", :downarrow},
    {"L_ARROW", :leftarrow},
    {"R_ARROW", :rightarrow},
    {"X360_DPAD_UP", :gp_dpad_up},
    {"X360_DPAD_DOWN", :gp_dpad_down},
    {"X360_DPAD_LEFT", :gp_dpad_left},
    {"X360_DPAD_RIGHT", :gp_dpad_right},
    {"X360_START", :gp_start},
    {"X360_BACK", :gp_back},
    {"X360_LEFT_THUMB", :gp_left_stick},
    {"X360_RIGHT_THUMB", :gp_right_stick},
    {"X360_LEFT_SHOULDER", :gp_left_shoulder},
    {"X360_RIGHT_SHOULDER", :gp_right_shoulder},
    {"X360_A", :gp_a},
    {"X360_B", :gp_b},
    {"X360_X", :gp_x},
    {"X360_Y", :gp_y},
    {"X360_LEFT_TRIGGER", :gp_left_trigger},
    {"X360_RIGHT_TRIGGER", :gp_right_trigger},
    {"X360_LEFT_THUMB_UP", :gp_left_thumb_up},
    {"X360_LEFT_THUMB_DOWN", :gp_left_thumb_down},
    {"X360_LEFT_THUMB_LEFT", :gp_left_thumb_left},
    {"X360_LEFT_THUMB_RIGHT", :gp_left_thumb_right},
    {"X360_RIGHT_THUMB_UP", :gp_right_thumb_up},
    {"X360_RIGHT_THUMB_DOWN", :gp_right_thumb_down},
    {"X360_RIGHT_THUMB_LEFT", :gp_right_thumb_left},
    {"X360_RIGHT_THUMB_RIGHT", :gp_right_thumb_right},
    {"LTHUMB", :gp_left_stick},
    {"RTHUMB", :gp_right_stick},
    {"LSHOULDER", :gp_left_shoulder},
    {"RSHOULDER", :gp_right_shoulder},
    {"ABUTTON", :gp_a},
    {"BBUTTON", :gp_b},
    {"XBUTTON", :gp_x},
    {"YBUTTON", :gp_y},
    {"LTRIGGER", :gp_left_trigger},
    {"RTRIGGER", :gp_right_trigger},
    {"SC_LPADDLE", :joy16},
    {"SC_RPADDLE", :joy17}
  ]

  @key_names Enum.map(
               @names ++ @joys ++ @auxes ++ @more_names,
               fn
                 {name, code} when is_integer(code) ->
                   {name, code}

                 {name, key} ->
                   {name, Map.fetch!(@numbers, Map.get(@aliases, key, key))}
               end
             )

  @qc_fixed [
              tab: 9,
              enter: 13,
              escape: 27,
              space: 32,
              backspace: 127,
              uparrow: 128,
              downarrow: 129,
              leftarrow: 130,
              rightarrow: 131,
              lalt: 132,
              lctrl: 133,
              lshift: 134,
              f1: 135,
              f2: 136,
              f3: 137,
              f4: 138,
              f5: 139,
              f6: 140,
              f7: 141,
              f8: 142,
              f9: 143,
              f10: 144,
              f11: 145,
              f12: 146,
              ins: 147,
              del: 148,
              pgdn: 149,
              pgup: 150,
              home: 151,
              end: 152,
              pause: 153,
              kp_numlock: 154,
              capslock: 155,
              scrlck: 156,
              kp_ins: 157,
              kp_end: 158,
              kp_downarrow: 159,
              kp_pgdn: 160,
              kp_leftarrow: 161,
              kp_5: 162,
              kp_rightarrow: 163,
              kp_home: 164,
              kp_uparrow: 165,
              kp_pgup: 166,
              kp_del: 167,
              kp_slash: 168,
              kp_star: 169,
              kp_minus: 170,
              kp_plus: 171,
              kp_enter: 172,
              kp_equals: 173,
              printscreen: 174,
              mouse1: 512,
              mouse2: 513,
              mouse3: 514,
              mwheelup: 515,
              mwheeldown: 516,
              mouse4: 517,
              mouse5: 518,
              mouse6: 519,
              mouse7: 520,
              mouse8: 521,
              mouse9: 522,
              mouse10: 523,
              touch: 600,
              touchslide: 601,
              touchtap: 602,
              touchlong: 603
            ] ++
              Enum.map(1..32, &{:"joy#{&1}", 767 + &1}) ++
              Enum.map(1..16, &{:"aux#{&1}", 799 + &1}) ++
              [
                gp_dpad_up: 816,
                gp_dpad_down: 817,
                gp_dpad_left: 818,
                gp_dpad_right: 819,
                gp_menu: 820,
                gp_view: 821,
                gp_left_stick: 822,
                gp_right_stick: 823,
                gp_left_shoulder: 824,
                gp_right_shoulder: 825,
                gp_diamond_down: 826,
                gp_diamond_right: 827,
                gp_diamond_left: 828,
                gp_diamond_up: 829,
                gp_left_trigger: 830,
                gp_right_trigger: 831,
                gp_left_thumb_up: 832,
                gp_left_thumb_down: 833,
                gp_left_thumb_left: 834,
                gp_left_thumb_right: 835,
                gp_right_thumb_up: 836,
                gp_right_thumb_down: 837,
                gp_right_thumb_left: 838,
                gp_right_thumb_right: 839,
                joy_up: 840,
                joy_down: 841,
                joy_left: 842,
                joy_right: 843
              ]

  @to_qc Map.new(@qc_fixed, fn {key, qc} -> {Map.fetch!(@numbers, key), qc} end)
  @from_qc Map.new(@qc_fixed, fn {key, qc} -> {qc, Map.fetch!(@numbers, key)} end)

  @modifier_prefixes [{"shift", 1}, {"ctrl", 4}, {"alt", 2}]

  @type keynum :: integer()
  @type modifier :: 0..15 | :all

  @doc "The number of FTE key `name` (an atom of `keynum_t` without its `K_`, lower case)."
  @spec keynum(atom()) :: keynum()
  def keynum(name), do: Map.fetch!(@numbers, Map.get(@aliases, name, name))

  @doc "One past the highest key number (FTE's `K_MAX`)."
  @spec max() :: pos_integer()
  def max, do: @max

  @doc "The QuakeC key code for key number `keynum` (FTE's `MP_TranslateFTEtoQCCodes`)."
  @spec to_qc(keynum()) :: integer()
  def to_qc(keynum) do
    case Map.fetch(@to_qc, keynum) do
      {:ok, qc} -> qc
      :error when keynum == -1 -> -1
      :error when keynum < 0 -> -keynum
      :error when keynum < 128 -> keynum
      :error -> -keynum
    end
  end

  @doc "The key number for QuakeC key code `code` (FTE's `MP_TranslateQCtoFTECodes`)."
  @spec from_qc(integer()) :: keynum()
  def from_qc(code) do
    case Map.fetch(@from_qc, code) do
      {:ok, keynum} -> keynum
      :error when code == -1 -> -1
      :error when code < 0 -> -code
      :error when code < 128 -> code
      :error -> -code
    end
  end

  @doc """
  The key number and modifier a key name such as `"w"`, `"MOUSE1"`, `"K_ENTER"`,
  `"ctrl+shift+a"` or `"std_f1"` names, or `{-1, modifier}` when it names no key
  (FTE's `Key_StringToKeynum`).
  """
  @spec string_to_keynum(String.t()) :: {keynum(), modifier()}
  def string_to_keynum(text) do
    {rest, modifier} = modifiers(text)
    {named(rest), modifier}
  end

  @doc """
  The name of key number `keynum` with `modifier` written before it (`Ctrl+`, `Alt+`,
  `Shift+` in that order; a bind map is not written), as FTE's `Key_KeynumToString`.
  """
  @spec keynum_to_string(keynum(), integer()) :: String.t()
  def keynum_to_string(keynum, modifier) do
    raw = raw_name(keynum)
    modifier = if String.starts_with?(raw, "<") and byte_size(raw) > 1, do: 0, else: modifier
    prefix(modifier) <> raw
  end

  defp prefix(7), do: "Ctrl+Alt+Shift+"
  defp prefix(3), do: "Alt+Shift+"
  defp prefix(5), do: "Ctrl+Shift+"
  defp prefix(6), do: "Ctrl+Alt+"
  defp prefix(4), do: "Ctrl+"
  defp prefix(2), do: "Alt+"
  defp prefix(1), do: "Shift+"
  defp prefix(_modifier), do: ""

  defp raw_name(keynum) when keynum < 0, do: "<KEY NOT FOUND>"

  defp raw_name(keynum) when keynum > 32 and keynum < 127 and keynum not in [?', ?", ?\\],
    do: <<keynum>>

  defp raw_name(keynum) do
    case Enum.find(@key_names, fn {_name, number} -> number == keynum end) do
      {name, _} -> name
      nil when keynum < 10 -> "0#{keynum}"
      nil -> Integer.to_string(keynum)
    end
  end

  defp modifiers(text) do
    if String.downcase(String.slice(text, 0, 4)) in ["std_", "std+"] do
      {String.slice(text, 4..-1//1), 0}
    else
      case strip(text, 0) do
        {rest, 0} -> {rest, :all}
        found -> found
      end
    end
  end

  defp strip(text, modifier) do
    Enum.find_value(@modifier_prefixes, {text, modifier}, fn {name, bit} ->
      size = byte_size(name)

      case text do
        <<head::binary-size(^size), separator, next, rest::binary>>
        when separator in [?+, ?\s] ->
          if String.downcase(head) == name, do: strip(<<next, rest::binary>>, bor(modifier, bit))

        _ ->
          nil
      end
    end)
  end

  defp named(""), do: -1

  defp named(<<char>>), do: ascii(char)

  defp named(text) do
    name = if String.starts_with?(text, "K_"), do: String.slice(text, 2..-1//1), else: text
    upper = String.upcase(name)

    case Enum.find(@key_names, fn {key_name, _} -> key_name == upper end) do
      {_, number} -> number
      nil -> name |> leading_integer() |> ascii()
    end
  end

  defp ascii(0), do: -1
  defp ascii(char) when char in ?A..?Z, do: char + 32
  defp ascii(char), do: char

  defp leading_integer(text) do
    case Integer.parse(String.trim_leading(text)) do
      {number, _} -> number
      :error -> 0
    end
  end
end
