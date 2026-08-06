"""Long fixture: 60 lines — enough to exceed the test window height.

Used by nvim_eob_gutter_scrolled.sh: cursor goes to the last line (G),
then the view is scrolled so that line sits at the top of the window (zt).
After scrolling, only a handful of EOB rows should be visible, and they
must remain periwinkle.
"""


def func_01(): return 1
def func_02(): return 2
def func_03(): return 3
def func_04(): return 4
def func_05(): return 5
def func_06(): return 6
def func_07(): return 7
def func_08(): return 8
def func_09(): return 9
def func_10(): return 10
def func_11(): return 11
def func_12(): return 12
def func_13(): return 13
def func_14(): return 14
def func_15(): return 15
def func_16(): return 16
def func_17(): return 17
def func_18(): return 18
def func_19(): return 19
def func_20(): return 20
def func_21(): return 21
def func_22(): return 22
def func_23(): return 23
def func_24(): return 24
def func_25(): return 25
def func_26(): return 26
def func_27(): return 27
def func_28(): return 28
def func_29(): return 29
def func_30(): return 30
def func_31(): return 31
def func_32(): return 32
def func_33(): return 33
def func_34(): return 34
def func_35(): return 35
def func_36(): return 36
def func_37(): return 37
def func_38(): return 38
def func_39(): return 39
def func_40(): return 40
def func_41(): return 41
def func_42(): return 42
def func_43(): return 43
def func_44(): return 44
def func_45(): return 45
def func_46(): return 46
def func_47(): return 47
def func_48(): return 48
def func_49(): return 49
# last line — cursor lands here for the scrolled-gutter test
LAST = 50
