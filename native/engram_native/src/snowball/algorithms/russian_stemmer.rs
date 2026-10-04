//! Generated from russian.sbl by Snowball 3.1.1 - https://snowballstem.org/

#![allow(non_snake_case)]
#![allow(non_upper_case_globals)]
#![allow(unused_mut)]
#![allow(unused_parens)]
#![allow(unused_variables)]
use crate::snowball::SnowballEnv;
use crate::snowball::Among;

#[derive(Clone)]
struct Context {
}

static A_0: &'static [Among<Context>; 9] = &[
    Among("вшись", -1, 1, None),
    Among("ывшись", 0, 2, None),
    Among("ившись", 0, 2, None),
    Among("в", -1, 1, None),
    Among("ыв", 3, 2, None),
    Among("ив", 3, 2, None),
    Among("вши", -1, 1, None),
    Among("ывши", 6, 2, None),
    Among("ивши", 6, 2, None),
];

static A_1: &'static [Among<Context>; 26] = &[
    Among("ему", -1, 1, None),
    Among("ому", -1, 1, None),
    Among("ых", -1, 1, None),
    Among("их", -1, 1, None),
    Among("ую", -1, 1, None),
    Among("юю", -1, 1, None),
    Among("ею", -1, 1, None),
    Among("ою", -1, 1, None),
    Among("яя", -1, 1, None),
    Among("ая", -1, 1, None),
    Among("ые", -1, 1, None),
    Among("ее", -1, 1, None),
    Among("ие", -1, 1, None),
    Among("ое", -1, 1, None),
    Among("ыми", -1, 1, None),
    Among("ими", -1, 1, None),
    Among("ый", -1, 1, None),
    Among("ей", -1, 1, None),
    Among("ий", -1, 1, None),
    Among("ой", -1, 1, None),
    Among("ым", -1, 1, None),
    Among("ем", -1, 1, None),
    Among("им", -1, 1, None),
    Among("ом", -1, 1, None),
    Among("его", -1, 1, None),
    Among("ого", -1, 1, None),
];

static A_2: &'static [Among<Context>; 8] = &[
    Among("вш", -1, 1, None),
    Among("ывш", 0, 2, None),
    Among("ивш", 0, 2, None),
    Among("щ", -1, 1, None),
    Among("ющ", 3, 1, None),
    Among("ующ", 4, 2, None),
    Among("ем", -1, 1, None),
    Among("нн", -1, 1, None),
];

static A_3: &'static [Among<Context>; 2] = &[
    Among("сь", -1, 1, None),
    Among("ся", -1, 1, None),
];

static A_4: &'static [Among<Context>; 46] = &[
    Among("ыт", -1, 2, None),
    Among("ют", -1, 1, None),
    Among("уют", 1, 2, None),
    Among("ят", -1, 2, None),
    Among("ет", -1, 1, None),
    Among("ует", 4, 2, None),
    Among("ит", -1, 2, None),
    Among("ны", -1, 1, None),
    Among("ены", 7, 2, None),
    Among("ть", -1, 1, None),
    Among("ыть", 9, 2, None),
    Among("ить", 9, 2, None),
    Among("ешь", -1, 1, None),
    Among("ишь", -1, 2, None),
    Among("ю", -1, 2, None),
    Among("ую", 14, 2, None),
    Among("ла", -1, 1, None),
    Among("ыла", 16, 2, None),
    Among("ила", 16, 2, None),
    Among("на", -1, 1, None),
    Among("ена", 19, 2, None),
    Among("ете", -1, 1, None),
    Among("ите", -1, 2, None),
    Among("йте", -1, 1, None),
    Among("уйте", 23, 2, None),
    Among("ейте", 23, 2, None),
    Among("ли", -1, 1, None),
    Among("ыли", 26, 2, None),
    Among("или", 26, 2, None),
    Among("й", -1, 1, None),
    Among("уй", 29, 2, None),
    Among("ей", 29, 2, None),
    Among("л", -1, 1, None),
    Among("ыл", 32, 2, None),
    Among("ил", 32, 2, None),
    Among("ым", -1, 2, None),
    Among("ем", -1, 1, None),
    Among("им", -1, 2, None),
    Among("н", -1, 1, None),
    Among("ен", 38, 2, None),
    Among("ло", -1, 1, None),
    Among("ыло", 40, 2, None),
    Among("ило", 40, 2, None),
    Among("но", -1, 1, None),
    Among("ено", 43, 2, None),
    Among("нно", 43, 1, None),
];

static A_5: &'static [Among<Context>; 36] = &[
    Among("у", -1, 1, None),
    Among("ях", -1, 1, None),
    Among("иях", 1, 1, None),
    Among("ах", -1, 1, None),
    Among("ы", -1, 1, None),
    Among("ь", -1, 1, None),
    Among("ю", -1, 1, None),
    Among("ью", 6, 1, None),
    Among("ию", 6, 1, None),
    Among("я", -1, 1, None),
    Among("ья", 9, 1, None),
    Among("ия", 9, 1, None),
    Among("а", -1, 1, None),
    Among("ев", -1, 1, None),
    Among("ов", -1, 1, None),
    Among("е", -1, 1, None),
    Among("ье", 15, 1, None),
    Among("ие", 15, 1, None),
    Among("и", -1, 1, None),
    Among("еи", 18, 1, None),
    Among("ии", 18, 1, None),
    Among("ями", 18, 1, None),
    Among("иями", 21, 1, None),
    Among("ами", 18, 1, None),
    Among("й", -1, 1, None),
    Among("ей", 24, 1, None),
    Among("ией", 25, 1, None),
    Among("ий", 24, 1, None),
    Among("ой", 24, 1, None),
    Among("ям", -1, 1, None),
    Among("иям", 29, 1, None),
    Among("ам", -1, 1, None),
    Among("ем", -1, 1, None),
    Among("ием", 32, 1, None),
    Among("ом", -1, 1, None),
    Among("о", -1, 1, None),
];

static A_6: &'static [Among<Context>; 2] = &[
    Among("ост", -1, 1, None),
    Among("ость", -1, 1, None),
];

static A_7: &'static [Among<Context>; 4] = &[
    Among("ейш", -1, 1, None),
    Among("ь", -1, 3, None),
    Among("ейше", -1, 1, None),
    Among("н", -1, 2, None),
];

static G_v: &'static [u8; 4] = &[33, 65, 8, 232];

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
    };
    let mut among_var;
    let mut i_p2 : i32;
    let mut i_pV : i32;
    let v_1 = env.cursor;
    'lab0: loop {
        'replab1: loop{
            let v_2 = env.cursor;
            'lab2: for _ in 0..1 {
                'golab3: loop {
                    let v_3 = env.cursor;
                    'lab4: loop {
                        env.bra = env.cursor;
                        if !env.eq_s(&"ё") {
                            break 'lab4;
                        }
                        env.ket = env.cursor;
                        env.cursor = v_3;
                        break 'golab3;
                    }
                    env.cursor = v_3;
                    if env.cursor >= env.limit {
                        break 'lab2;
                    }
                    env.next_char();
                }
                env.slice_from("е");
                continue 'replab1;
            }
            env.cursor = v_2;
            break 'replab1;
        }
        break 'lab0;
    }
    env.cursor = v_1;
    'lab5: loop {
        i_pV = env.limit;
        i_p2 = env.limit;
        let v_4 = env.cursor;
        'lab6: loop {
            if !env.go_out_grouping(G_v, 1072, 1103) {
                break 'lab6;
            }
            env.next_char();
            i_pV = env.cursor;
            if !env.go_in_grouping(G_v, 1072, 1103) {
                break 'lab6;
            }
            env.next_char();
            if !env.go_out_grouping(G_v, 1072, 1103) {
                break 'lab6;
            }
            env.next_char();
            if !env.go_in_grouping(G_v, 1072, 1103) {
                break 'lab6;
            }
            env.next_char();
            i_p2 = env.cursor;
            break 'lab6;
        }
        env.cursor = v_4;
        break 'lab5;
    }
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    if env.cursor < i_pV {
        return false;
    }
    let v_5 = env.limit_backward;
    env.limit_backward = i_pV;
    let v_6 = env.limit - env.cursor;
    'lab7: loop {
        'lab8: loop {
            let v_7 = env.limit - env.cursor;
            'lab9: loop {
                env.ket = env.cursor;
                among_var = env.find_among_b(A_0, context);
                if among_var == 0 {
                    break 'lab9;
                }
                env.bra = env.cursor;
                match among_var {
                    1 => {
                        'lab10: loop {
                            'lab11: loop {
                                if !env.eq_s_b(&"а") {
                                    break 'lab11;
                                }
                                break 'lab10;
                            }
                            if !env.eq_s_b(&"я") {
                                break 'lab9;
                            }
                            break 'lab10;
                        }
                        env.slice_del();
                    }
                    2 => {
                        env.slice_del();
                    }
                    _ => ()
                }
                break 'lab8;
            }
            env.cursor = env.limit - v_7;
            let v_8 = env.limit - env.cursor;
            'lab12: loop {
                env.ket = env.cursor;
                if (env.cursor - 3 <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 140 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 143 as u8)) {
                    env.cursor = env.limit - v_8;
                    break 'lab12;
                }

                if env.find_among_b(A_3, context) == 0 {
                    env.cursor = env.limit - v_8;
                    break 'lab12;
                }
                env.bra = env.cursor;
                env.slice_del();
                break 'lab12;
            }
            'lab13: loop {
                let v_9 = env.limit - env.cursor;
                'lab14: loop {
                    env.ket = env.cursor;
                    if env.find_among_b(A_1, context) == 0 {
                        break 'lab14;
                    }
                    env.bra = env.cursor;
                    env.slice_del();
                    let v_10 = env.limit - env.cursor;
                    'lab15: loop {
                        env.ket = env.cursor;
                        among_var = env.find_among_b(A_2, context);
                        if among_var == 0 {
                            env.cursor = env.limit - v_10;
                            break 'lab15;
                        }
                        env.bra = env.cursor;
                        match among_var {
                            1 => {
                                'lab16: loop {
                                    'lab17: loop {
                                        if !env.eq_s_b(&"а") {
                                            break 'lab17;
                                        }
                                        break 'lab16;
                                    }
                                    if !env.eq_s_b(&"я") {
                                        env.cursor = env.limit - v_10;
                                        break 'lab15;
                                    }
                                    break 'lab16;
                                }
                                env.slice_del();
                            }
                            2 => {
                                env.slice_del();
                            }
                            _ => ()
                        }
                        break 'lab15;
                    }
                    break 'lab13;
                }
                env.cursor = env.limit - v_9;
                'lab18: loop {
                    env.ket = env.cursor;
                    among_var = env.find_among_b(A_4, context);
                    if among_var == 0 {
                        break 'lab18;
                    }
                    env.bra = env.cursor;
                    match among_var {
                        1 => {
                            'lab19: loop {
                                'lab20: loop {
                                    if !env.eq_s_b(&"а") {
                                        break 'lab20;
                                    }
                                    break 'lab19;
                                }
                                if !env.eq_s_b(&"я") {
                                    break 'lab18;
                                }
                                break 'lab19;
                            }
                            env.slice_del();
                        }
                        2 => {
                            env.slice_del();
                        }
                        _ => ()
                    }
                    break 'lab13;
                }
                env.cursor = env.limit - v_9;
                env.ket = env.cursor;
                if env.find_among_b(A_5, context) == 0 {
                    break 'lab7;
                }
                env.bra = env.cursor;
                env.slice_del();
                break 'lab13;
            }
            break 'lab8;
        }
        break 'lab7;
    }
    env.cursor = env.limit - v_6;
    let v_11 = env.limit - env.cursor;
    'lab21: loop {
        env.ket = env.cursor;
        if !env.eq_s_b(&"и") {
            env.cursor = env.limit - v_11;
            break 'lab21;
        }
        env.bra = env.cursor;
        env.slice_del();
        break 'lab21;
    }
    let v_12 = env.limit - env.cursor;
    'lab22: loop {
        env.ket = env.cursor;
        if (env.cursor - 5 <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 130 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 140 as u8)) {
            break 'lab22;
        }

        if env.find_among_b(A_6, context) == 0 {
            break 'lab22;
        }
        env.bra = env.cursor;
        if i_p2 > env.cursor {
            break 'lab22;
        }
        env.slice_del();
        break 'lab22;
    }
    env.cursor = env.limit - v_12;
    let v_13 = env.limit - env.cursor;
    'lab23: loop {
        env.ket = env.cursor;
        among_var = env.find_among_b(A_7, context);
        if among_var == 0 {
            break 'lab23;
        }
        env.bra = env.cursor;
        match among_var {
            1 => {
                env.slice_del();
                env.ket = env.cursor;
                if !env.eq_s_b(&"н") {
                    break 'lab23;
                }
                env.bra = env.cursor;
                if !env.eq_s_b(&"н") {
                    break 'lab23;
                }
                env.slice_del();
            }
            2 => {
                if !env.eq_s_b(&"н") {
                    break 'lab23;
                }
                env.slice_del();
            }
            3 => {
                env.slice_del();
            }
            _ => ()
        }
        break 'lab23;
    }
    env.cursor = env.limit - v_13;
    env.limit_backward = v_5;
    env.cursor = env.limit_backward;
    return true
}
