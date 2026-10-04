//! Generated from german.sbl by Snowball 3.1.1 - https://snowballstem.org/

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

static A_0: &'static [Among<Context>; 6] = &[
    Among("", -1, 5, None),
    Among("ae", 0, 2, None),
    Among("oe", 0, 3, None),
    Among("qu", 0, -1, None),
    Among("ue", 0, 4, None),
    Among("ß", 0, 1, None),
];

static A_1: &'static [Among<Context>; 6] = &[
    Among("", -1, 5, None),
    Among("U", 0, 2, None),
    Among("Y", 0, 1, None),
    Among("ä", 0, 3, None),
    Among("ö", 0, 4, None),
    Among("ü", 0, 2, None),
];

static A_2: &'static [Among<Context>; 11] = &[
    Among("e", -1, 3, None),
    Among("em", -1, 1, None),
    Among("en", -1, 3, None),
    Among("erinnen", 2, 2, None),
    Among("erin", -1, 2, None),
    Among("ln", -1, 5, None),
    Among("ern", -1, 2, None),
    Among("er", -1, 2, None),
    Among("s", -1, 4, None),
    Among("es", 8, 3, None),
    Among("lns", 8, 5, None),
];

static A_3: &'static [Among<Context>; 5] = &[
    Among("tick", -1, -1, None),
    Among("plan", -1, -1, None),
    Among("geordn", -1, -1, None),
    Among("intern", -1, -1, None),
    Among("tr", -1, -1, None),
];

static A_4: &'static [Among<Context>; 5] = &[
    Among("en", -1, 1, None),
    Among("er", -1, 1, None),
    Among("et", -1, 3, None),
    Among("st", -1, 2, None),
    Among("est", 3, 1, None),
];

static A_5: &'static [Among<Context>; 2] = &[
    Among("ig", -1, 1, None),
    Among("lich", -1, 1, None),
];

static A_6: &'static [Among<Context>; 8] = &[
    Among("end", -1, 1, None),
    Among("ig", -1, 2, None),
    Among("ung", -1, 1, None),
    Among("lich", -1, 3, None),
    Among("isch", -1, 2, None),
    Among("ik", -1, 2, None),
    Among("heit", -1, 3, None),
    Among("keit", -1, 4, None),
];

static G_v: &'static [u8; 20] = &[17, 65, 16, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 32, 8];

static G_et_ending: &'static [u8; 18] = &[1, 128, 198, 227, 32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128];

static G_s_ending: &'static [u8; 3] = &[117, 30, 5];

static G_st_ending: &'static [u8; 3] = &[117, 30, 4];

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
    };
    let mut among_var;
    let mut i_x : i32;
    let mut i_p2 : i32;
    let mut i_p1 : i32;
    let v_1 = env.cursor;
    'lab0: loop {
        let v_2 = env.cursor;
        'replab1: loop{
            let v_3 = env.cursor;
            'lab2: for _ in 0..1 {
                'golab3: loop {
                    let v_4 = env.cursor;
                    'lab4: loop {
                        if !env.in_grouping(G_v, 97, 252) {
                            break 'lab4;
                        }
                        env.bra = env.cursor;
                        'lab5: loop {
                            let v_5 = env.cursor;
                            'lab6: loop {
                                if !env.eq_s(&"u") {
                                    break 'lab6;
                                }
                                env.ket = env.cursor;
                                if !env.in_grouping(G_v, 97, 252) {
                                    break 'lab6;
                                }
                                env.slice_from("U");
                                break 'lab5;
                            }
                            env.cursor = v_5;
                            if !env.eq_s(&"y") {
                                break 'lab4;
                            }
                            env.ket = env.cursor;
                            if !env.in_grouping(G_v, 97, 252) {
                                break 'lab4;
                            }
                            env.slice_from("Y");
                            break 'lab5;
                        }
                        env.cursor = v_4;
                        break 'golab3;
                    }
                    env.cursor = v_4;
                    if env.cursor >= env.limit {
                        break 'lab2;
                    }
                    env.next_char();
                }
                continue 'replab1;
            }
            env.cursor = v_3;
            break 'replab1;
        }
        env.cursor = v_2;
        'replab7: loop{
            let v_6 = env.cursor;
            'lab8: for _ in 0..1 {
                env.bra = env.cursor;
                among_var = env.find_among(A_0, context);
                env.ket = env.cursor;
                match among_var {
                    1 => {
                        env.slice_from("ss");
                    }
                    2 => {
                        env.slice_from("ä");
                    }
                    3 => {
                        env.slice_from("ö");
                    }
                    4 => {
                        env.slice_from("ü");
                    }
                    5 => {
                        if env.cursor >= env.limit {
                            break 'lab8;
                        }
                        env.next_char();
                    }
                    _ => ()
                }
                continue 'replab7;
            }
            env.cursor = v_6;
            break 'replab7;
        }
        break 'lab0;
    }
    env.cursor = v_1;
    let v_7 = env.cursor;
    'lab9: loop {
        i_p1 = env.limit;
        i_p2 = env.limit;
        let v_8 = env.cursor;
        if !env.hop(3) {
            break 'lab9;
        }
        i_x = env.cursor;
        env.cursor = v_8;
        if !env.go_out_grouping(G_v, 97, 252) {
            break 'lab9;
        }
        env.next_char();
        if !env.go_in_grouping(G_v, 97, 252) {
            break 'lab9;
        }
        env.next_char();
        i_p1 = env.cursor;
        'lab10: loop {
            if i_p1 >= i_x {
                break 'lab10;
            }
            i_p1 = i_x;
            break 'lab10;
        }
        if !env.go_out_grouping(G_v, 97, 252) {
            break 'lab9;
        }
        env.next_char();
        if !env.go_in_grouping(G_v, 97, 252) {
            break 'lab9;
        }
        env.next_char();
        i_p2 = env.cursor;
        break 'lab9;
    }
    env.cursor = v_7;
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    'lab11: loop {
        let v_9 = env.limit - env.cursor;
        'lab12: loop {
            env.ket = env.cursor;
            if (env.cursor <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((811040 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                break 'lab12;
            }

            among_var = env.find_among_b(A_2, context);
            if among_var == 0 {
                break 'lab12;
            }
            env.bra = env.cursor;
            if i_p1 > env.cursor {
                break 'lab12;
            }
            match among_var {
                1 => {
                    'lab13: loop {
                        if !env.eq_s_b(&"syst") {
                            break 'lab13;
                        }
                        break 'lab12;
                    }
                    env.slice_del();
                }
                2 => {
                    env.slice_del();
                }
                3 => {
                    env.slice_del();
                    let v_10 = env.limit - env.cursor;
                    'lab14: loop {
                        env.ket = env.cursor;
                        if !env.eq_s_b(&"s") {
                            env.cursor = env.limit - v_10;
                            break 'lab14;
                        }
                        env.bra = env.cursor;
                        if !env.eq_s_b(&"nis") {
                            env.cursor = env.limit - v_10;
                            break 'lab14;
                        }
                        env.slice_del();
                        break 'lab14;
                    }
                }
                4 => {
                    if !env.in_grouping_b(G_s_ending, 98, 116) {
                        break 'lab12;
                    }
                    env.slice_del();
                }
                5 => {
                    env.slice_from("l");
                }
                _ => ()
            }
            break 'lab12;
        }
        env.cursor = env.limit - v_9;
        let v_11 = env.limit - env.cursor;
        'lab15: loop {
            env.ket = env.cursor;
            if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((1327104 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                break 'lab15;
            }

            among_var = env.find_among_b(A_4, context);
            if among_var == 0 {
                break 'lab15;
            }
            env.bra = env.cursor;
            if i_p1 > env.cursor {
                break 'lab15;
            }
            match among_var {
                1 => {
                    env.slice_del();
                }
                2 => {
                    if !env.in_grouping_b(G_st_ending, 98, 116) {
                        break 'lab15;
                    }
                    if !env.hop_back(3) {
                        break 'lab15;
                    }
                    env.slice_del();
                }
                3 => {
                    let v_12 = env.limit - env.cursor;
                    if !env.in_grouping_b(G_et_ending, 85, 228) {
                        break 'lab15;
                    }
                    env.cursor = env.limit - v_12;
                    let v_13 = env.limit - env.cursor;
                    'lab16: loop {
                        if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((280576 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                            break 'lab16;
                        }

                        if env.find_among_b(A_3, context) == 0 {
                            break 'lab16;
                        }
                        break 'lab15;
                    }
                    env.cursor = env.limit - v_13;
                    env.slice_del();
                }
                _ => ()
            }
            break 'lab15;
        }
        env.cursor = env.limit - v_11;
        let v_14 = env.limit - env.cursor;
        'lab17: loop {
            env.ket = env.cursor;
            if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((1051024 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                break 'lab17;
            }

            among_var = env.find_among_b(A_6, context);
            if among_var == 0 {
                break 'lab17;
            }
            env.bra = env.cursor;
            if i_p2 > env.cursor {
                break 'lab17;
            }
            match among_var {
                1 => {
                    env.slice_del();
                    let v_15 = env.limit - env.cursor;
                    'lab18: loop {
                        env.ket = env.cursor;
                        if !env.eq_s_b(&"ig") {
                            env.cursor = env.limit - v_15;
                            break 'lab18;
                        }
                        env.bra = env.cursor;
                        'lab19: loop {
                            if !env.eq_s_b(&"e") {
                                break 'lab19;
                            }
                            env.cursor = env.limit - v_15;
                            break 'lab18;
                        }
                        if i_p2 > env.cursor {
                            env.cursor = env.limit - v_15;
                            break 'lab18;
                        }
                        env.slice_del();
                        break 'lab18;
                    }
                }
                2 => {
                    'lab20: loop {
                        if !env.eq_s_b(&"e") {
                            break 'lab20;
                        }
                        break 'lab17;
                    }
                    env.slice_del();
                }
                3 => {
                    env.slice_del();
                    let v_16 = env.limit - env.cursor;
                    'lab21: loop {
                        env.ket = env.cursor;
                        'lab22: loop {
                            'lab23: loop {
                                if !env.eq_s_b(&"er") {
                                    break 'lab23;
                                }
                                break 'lab22;
                            }
                            if !env.eq_s_b(&"en") {
                                env.cursor = env.limit - v_16;
                                break 'lab21;
                            }
                            break 'lab22;
                        }
                        env.bra = env.cursor;
                        if i_p1 > env.cursor {
                            env.cursor = env.limit - v_16;
                            break 'lab21;
                        }
                        env.slice_del();
                        break 'lab21;
                    }
                }
                4 => {
                    env.slice_del();
                    let v_17 = env.limit - env.cursor;
                    'lab24: loop {
                        env.ket = env.cursor;
                        if (env.cursor - 1 <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 103 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 104 as u8)) {
                            env.cursor = env.limit - v_17;
                            break 'lab24;
                        }

                        if env.find_among_b(A_5, context) == 0 {
                            env.cursor = env.limit - v_17;
                            break 'lab24;
                        }
                        env.bra = env.cursor;
                        if i_p2 > env.cursor {
                            env.cursor = env.limit - v_17;
                            break 'lab24;
                        }
                        env.slice_del();
                        break 'lab24;
                    }
                }
                _ => ()
            }
            break 'lab17;
        }
        env.cursor = env.limit - v_14;
        break 'lab11;
    }
    env.cursor = env.limit_backward;
    let v_18 = env.cursor;
    'lab25: loop {
        'replab26: loop{
            let v_19 = env.cursor;
            'lab27: for _ in 0..1 {
                env.bra = env.cursor;
                among_var = env.find_among(A_1, context);
                env.ket = env.cursor;
                match among_var {
                    1 => {
                        env.slice_from("y");
                    }
                    2 => {
                        env.slice_from("u");
                    }
                    3 => {
                        env.slice_from("a");
                    }
                    4 => {
                        env.slice_from("o");
                    }
                    5 => {
                        if env.cursor >= env.limit {
                            break 'lab27;
                        }
                        env.next_char();
                    }
                    _ => ()
                }
                continue 'replab26;
            }
            env.cursor = v_19;
            break 'replab26;
        }
        break 'lab25;
    }
    env.cursor = v_18;
    return true
}
