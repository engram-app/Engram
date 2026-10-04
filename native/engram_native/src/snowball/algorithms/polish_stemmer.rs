//! Generated from polish.sbl by Snowball 3.1.1 - https://snowballstem.org/

#![allow(non_snake_case)]
#![allow(non_upper_case_globals)]
#![allow(unused_mut)]
#![allow(unused_parens)]
#![allow(unused_variables)]
use crate::snowball::SnowballEnv;
use crate::snowball::Among;

#[derive(Clone)]
struct Context {
    i_p1: i32,
}

static A_0: &'static [Among<Context>; 5] = &[
    Among("byście", -1, 1, None),
    Among("bym", -1, 1, None),
    Among("by", -1, 1, None),
    Among("byśmy", -1, 1, None),
    Among("byś", -1, 1, None),
];

static A_1: &'static [Among<Context>; 5] = &[
    Among("ąc", -1, 1, None),
    Among("ając", 0, 1, None),
    Among("sząc", 0, 2, None),
    Among("sz", -1, 1, None),
    Among("iejsz", 3, 1, None),
];

static A_2: &'static [Among<Context>; 118] = &[
    Among("a", -1, 1, Some(&r_R1)),
    Among("ąca", 0, 1, None),
    Among("ająca", 1, 1, None),
    Among("sząca", 1, 2, None),
    Among("ia", 0, 1, Some(&r_R1)),
    Among("sza", 0, 1, None),
    Among("iejsza", 5, 1, None),
    Among("ała", 0, 1, None),
    Among("iała", 7, 1, None),
    Among("iła", 0, 1, None),
    Among("ąc", -1, 1, None),
    Among("ając", 10, 1, None),
    Among("e", -1, 1, Some(&r_R1)),
    Among("ące", 12, 1, None),
    Among("ające", 13, 1, None),
    Among("szące", 13, 2, None),
    Among("ie", 12, 1, Some(&r_R1)),
    Among("cie", 16, 1, None),
    Among("acie", 17, 1, None),
    Among("ecie", 17, 1, None),
    Among("icie", 17, 1, None),
    Among("ajcie", 17, 1, None),
    Among("liście", 17, 4, None),
    Among("aliście", 22, 1, None),
    Among("ieliście", 22, 1, None),
    Among("iliście", 22, 1, None),
    Among("łyście", 17, 4, None),
    Among("ałyście", 26, 1, None),
    Among("iałyście", 27, 1, None),
    Among("iłyście", 26, 1, None),
    Among("sze", 12, 1, None),
    Among("iejsze", 30, 1, None),
    Among("ach", -1, 1, Some(&r_R1)),
    Among("iach", 32, 1, Some(&r_R1)),
    Among("ich", -1, 5, None),
    Among("ych", -1, 5, None),
    Among("i", -1, 1, Some(&r_R1)),
    Among("ali", 36, 1, None),
    Among("ieli", 36, 1, None),
    Among("ili", 36, 1, None),
    Among("ami", 36, 1, Some(&r_R1)),
    Among("iami", 40, 1, Some(&r_R1)),
    Among("imi", 36, 5, None),
    Among("ymi", 36, 5, None),
    Among("owi", 36, 1, Some(&r_R1)),
    Among("iowi", 44, 1, Some(&r_R1)),
    Among("aj", -1, 1, None),
    Among("ej", -1, 5, None),
    Among("iej", 47, 5, None),
    Among("am", -1, 1, None),
    Among("ałam", 49, 1, None),
    Among("iałam", 50, 1, None),
    Among("iłam", 49, 1, None),
    Among("em", -1, 1, Some(&r_R1)),
    Among("iem", 53, 1, Some(&r_R1)),
    Among("ałem", 53, 1, None),
    Among("iałem", 55, 1, None),
    Among("iłem", 53, 1, None),
    Among("im", -1, 5, None),
    Among("om", -1, 1, Some(&r_R1)),
    Among("iom", 59, 1, Some(&r_R1)),
    Among("ym", -1, 5, None),
    Among("o", -1, 1, Some(&r_R1)),
    Among("ego", 62, 5, None),
    Among("iego", 63, 5, None),
    Among("ało", 62, 1, None),
    Among("iało", 65, 1, None),
    Among("iło", 62, 1, None),
    Among("u", -1, 1, Some(&r_R1)),
    Among("iu", 68, 1, Some(&r_R1)),
    Among("emu", 68, 5, None),
    Among("iemu", 70, 5, None),
    Among("ów", -1, 1, Some(&r_R1)),
    Among("y", -1, 5, None),
    Among("amy", 73, 1, None),
    Among("emy", 73, 1, None),
    Among("imy", 73, 1, None),
    Among("liśmy", 73, 4, None),
    Among("aliśmy", 77, 1, None),
    Among("ieliśmy", 77, 1, None),
    Among("iliśmy", 77, 1, None),
    Among("łyśmy", 73, 4, None),
    Among("ałyśmy", 81, 1, None),
    Among("iałyśmy", 82, 1, None),
    Among("iłyśmy", 81, 1, None),
    Among("ały", 73, 1, None),
    Among("iały", 85, 1, None),
    Among("iły", 73, 1, None),
    Among("asz", -1, 1, None),
    Among("esz", -1, 1, None),
    Among("isz", -1, 1, None),
    Among("ał", -1, 1, None),
    Among("iał", 91, 1, None),
    Among("ił", -1, 1, None),
    Among("ą", -1, 1, Some(&r_R1)),
    Among("ącą", 94, 1, None),
    Among("ającą", 95, 1, None),
    Among("szącą", 95, 2, None),
    Among("ią", 94, 1, Some(&r_R1)),
    Among("ają", 94, 1, None),
    Among("szą", 94, 3, None),
    Among("iejszą", 100, 1, None),
    Among("ać", -1, 1, None),
    Among("ieć", -1, 1, None),
    Among("ić", -1, 1, None),
    Among("ąć", -1, 1, None),
    Among("aść", -1, 1, None),
    Among("eść", -1, 1, None),
    Among("ę", -1, 1, None),
    Among("szę", 108, 2, None),
    Among("łaś", -1, 4, None),
    Among("ałaś", 110, 1, None),
    Among("iałaś", 111, 1, None),
    Among("iłaś", 110, 1, None),
    Among("łeś", -1, 4, None),
    Among("ałeś", 114, 1, None),
    Among("iałeś", 115, 1, None),
    Among("iłeś", 114, 1, None),
];

static A_3: &'static [Among<Context>; 4] = &[
    Among("ń", -1, 2, None),
    Among("ć", -1, 1, None),
    Among("ś", -1, 3, None),
    Among("ź", -1, 4, None),
];

static G_v: &'static [u8; 24] = &[17, 65, 16, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 16, 0, 0, 1];

fn r_R1(env: &mut SnowballEnv, context: &mut Context) -> bool {
    return context.i_p1 <= env.cursor
}

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
        i_p1: 0,
    };
    let mut among_var;
    let v_1 = env.cursor;
    'lab0: loop {
        context.i_p1 = env.limit;
        if !env.go_out_grouping(G_v, 97, 281) {
            break 'lab0;
        }
        env.next_char();
        if !env.go_in_grouping(G_v, 97, 281) {
            break 'lab0;
        }
        env.next_char();
        context.i_p1 = env.cursor;
        break 'lab0;
    }
    env.cursor = v_1;
    'lab1: loop {
        let v_2 = env.cursor;
        'lab2: loop {
            if !env.hop(2) {
                break 'lab2;
            }
            env.limit_backward = env.cursor;
            env.cursor = env.limit;
            let v_3 = env.limit - env.cursor;
            'lab3: loop {
                if env.cursor < context.i_p1 {
                    break 'lab3;
                }
                let v_4 = env.limit_backward;
                env.limit_backward = context.i_p1;
                env.ket = env.cursor;
                if env.find_among_b(A_0, context) == 0 {
                    env.limit_backward = v_4;
                    break 'lab3;
                }
                env.bra = env.cursor;
                env.limit_backward = v_4;
                env.slice_del();
                break 'lab3;
            }
            env.cursor = env.limit - v_3;
            env.ket = env.cursor;
            among_var = env.find_among_b(A_2, context);
            if among_var == 0 {
                break 'lab2;
            }
            env.bra = env.cursor;
            match among_var {
                1 => {
                    env.slice_del();
                }
                2 => {
                    env.slice_from("s");
                }
                3 => {
                    'lab4: loop {
                        let v_5 = env.limit - env.cursor;
                        'lab5: loop {
                            if context.i_p1 > env.cursor {
                                break 'lab5;
                            }
                            env.slice_del();
                            break 'lab4;
                        }
                        env.cursor = env.limit - v_5;
                        env.slice_from("s");
                        break 'lab4;
                    }
                }
                4 => {
                    env.slice_from("ł");
                }
                5 => {
                    env.slice_del();
                    let v_6 = env.limit - env.cursor;
                    'lab6: loop {
                        env.ket = env.cursor;
                        if (env.cursor - 1 <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 99 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 122 as u8)) {
                            env.cursor = env.limit - v_6;
                            break 'lab6;
                        }

                        among_var = env.find_among_b(A_1, context);
                        if among_var == 0 {
                            env.cursor = env.limit - v_6;
                            break 'lab6;
                        }
                        env.bra = env.cursor;
                        match among_var {
                            1 => {
                                env.slice_del();
                            }
                            2 => {
                                env.slice_from("s");
                            }
                            _ => ()
                        }
                        break 'lab6;
                    }
                }
                _ => ()
            }
            let v_7 = env.limit - env.cursor;
            'lab7: loop {
                env.ket = env.cursor;
                if !env.eq_s_b(&"'") {
                    env.cursor = env.limit - v_7;
                    break 'lab7;
                }
                env.bra = env.cursor;
                env.slice_del();
                break 'lab7;
            }
            env.cursor = env.limit_backward;
            break 'lab1;
        }
        env.cursor = v_2;
        env.limit_backward = env.cursor;
        env.cursor = env.limit;
        env.ket = env.cursor;
        among_var = env.find_among_b(A_3, context);
        if among_var == 0 {
            return false;
        }
        env.bra = env.cursor;
        if env.cursor <= env.limit_backward {
            return false;
        }
        match among_var {
            1 => {
                env.slice_from("c");
            }
            2 => {
                env.slice_from("n");
            }
            3 => {
                env.slice_from("s");
            }
            4 => {
                env.slice_from("z");
            }
            _ => ()
        }
        env.cursor = env.limit_backward;
        break 'lab1;
    }
    return true
}
