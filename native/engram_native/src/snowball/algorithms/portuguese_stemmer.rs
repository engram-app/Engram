//! Generated from portuguese.sbl by Snowball 3.1.1 - https://snowballstem.org/

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

static A_0: &'static [Among<Context>; 3] = &[
    Among("", -1, 3, None),
    Among("ã", 0, 1, None),
    Among("õ", 0, 2, None),
];

static A_1: &'static [Among<Context>; 3] = &[
    Among("", -1, 3, None),
    Among("a~", 0, 1, None),
    Among("o~", 0, 2, None),
];

static A_2: &'static [Among<Context>; 4] = &[
    Among("ic", -1, -1, None),
    Among("ad", -1, -1, None),
    Among("os", -1, -1, None),
    Among("iv", -1, 1, None),
];

static A_3: &'static [Among<Context>; 3] = &[
    Among("ante", -1, 1, None),
    Among("avel", -1, 1, None),
    Among("ível", -1, 1, None),
];

static A_4: &'static [Among<Context>; 3] = &[
    Among("ic", -1, 1, None),
    Among("abil", -1, 1, None),
    Among("iv", -1, 1, None),
];

static A_5: &'static [Among<Context>; 45] = &[
    Among("ica", -1, 1, None),
    Among("ância", -1, 1, None),
    Among("ência", -1, 4, None),
    Among("logia", -1, 2, None),
    Among("ira", -1, 9, None),
    Among("adora", -1, 1, None),
    Among("osa", -1, 1, None),
    Among("ista", -1, 1, None),
    Among("iva", -1, 8, None),
    Among("eza", -1, 1, None),
    Among("idade", -1, 7, None),
    Among("ante", -1, 1, None),
    Among("mente", -1, 6, None),
    Among("amente", 12, 5, None),
    Among("ável", -1, 1, None),
    Among("ível", -1, 1, None),
    Among("ico", -1, 1, None),
    Among("ismo", -1, 1, None),
    Among("oso", -1, 1, None),
    Among("amento", -1, 1, None),
    Among("imento", -1, 1, None),
    Among("ivo", -1, 8, None),
    Among("aça~o", -1, 1, None),
    Among("uça~o", -1, 3, None),
    Among("ador", -1, 1, None),
    Among("icas", -1, 1, None),
    Among("ências", -1, 4, None),
    Among("logias", -1, 2, None),
    Among("iras", -1, 9, None),
    Among("adoras", -1, 1, None),
    Among("osas", -1, 1, None),
    Among("istas", -1, 1, None),
    Among("ivas", -1, 8, None),
    Among("ezas", -1, 1, None),
    Among("idades", -1, 7, None),
    Among("adores", -1, 1, None),
    Among("antes", -1, 1, None),
    Among("aço~es", -1, 1, None),
    Among("uço~es", -1, 3, None),
    Among("icos", -1, 1, None),
    Among("ismos", -1, 1, None),
    Among("osos", -1, 1, None),
    Among("amentos", -1, 1, None),
    Among("imentos", -1, 1, None),
    Among("ivos", -1, 8, None),
];

static A_6: &'static [Among<Context>; 120] = &[
    Among("ada", -1, 1, None),
    Among("ida", -1, 1, None),
    Among("ia", -1, 1, None),
    Among("aria", 2, 1, None),
    Among("eria", 2, 1, None),
    Among("iria", 2, 1, None),
    Among("ara", -1, 1, None),
    Among("era", -1, 1, None),
    Among("ira", -1, 1, None),
    Among("ava", -1, 1, None),
    Among("asse", -1, 1, None),
    Among("esse", -1, 1, None),
    Among("isse", -1, 1, None),
    Among("aste", -1, 1, None),
    Among("este", -1, 1, None),
    Among("iste", -1, 1, None),
    Among("ei", -1, 1, None),
    Among("arei", 16, 1, None),
    Among("erei", 16, 1, None),
    Among("irei", 16, 1, None),
    Among("am", -1, 1, None),
    Among("iam", 20, 1, None),
    Among("ariam", 21, 1, None),
    Among("eriam", 21, 1, None),
    Among("iriam", 21, 1, None),
    Among("aram", 20, 1, None),
    Among("eram", 20, 1, None),
    Among("iram", 20, 1, None),
    Among("avam", 20, 1, None),
    Among("em", -1, 1, None),
    Among("arem", 29, 1, None),
    Among("erem", 29, 1, None),
    Among("irem", 29, 1, None),
    Among("assem", 29, 1, None),
    Among("essem", 29, 1, None),
    Among("issem", 29, 1, None),
    Among("ado", -1, 1, None),
    Among("ido", -1, 1, None),
    Among("ando", -1, 1, None),
    Among("endo", -1, 1, None),
    Among("indo", -1, 1, None),
    Among("ara~o", -1, 1, None),
    Among("era~o", -1, 1, None),
    Among("ira~o", -1, 1, None),
    Among("ar", -1, 1, None),
    Among("er", -1, 1, None),
    Among("ir", -1, 1, None),
    Among("as", -1, 1, None),
    Among("adas", 47, 1, None),
    Among("idas", 47, 1, None),
    Among("ias", 47, 1, None),
    Among("arias", 50, 1, None),
    Among("erias", 50, 1, None),
    Among("irias", 50, 1, None),
    Among("aras", 47, 1, None),
    Among("eras", 47, 1, None),
    Among("iras", 47, 1, None),
    Among("avas", 47, 1, None),
    Among("es", -1, 1, None),
    Among("ardes", 58, 1, None),
    Among("erdes", 58, 1, None),
    Among("irdes", 58, 1, None),
    Among("ares", 58, 1, None),
    Among("eres", 58, 1, None),
    Among("ires", 58, 1, None),
    Among("asses", 58, 1, None),
    Among("esses", 58, 1, None),
    Among("isses", 58, 1, None),
    Among("astes", 58, 1, None),
    Among("estes", 58, 1, None),
    Among("istes", 58, 1, None),
    Among("is", -1, 1, None),
    Among("ais", 71, 1, None),
    Among("eis", 71, 1, None),
    Among("areis", 73, 1, None),
    Among("ereis", 73, 1, None),
    Among("ireis", 73, 1, None),
    Among("áreis", 73, 1, None),
    Among("éreis", 73, 1, None),
    Among("íreis", 73, 1, None),
    Among("ásseis", 73, 1, None),
    Among("ésseis", 73, 1, None),
    Among("ísseis", 73, 1, None),
    Among("áveis", 73, 1, None),
    Among("íeis", 73, 1, None),
    Among("aríeis", 84, 1, None),
    Among("eríeis", 84, 1, None),
    Among("iríeis", 84, 1, None),
    Among("ados", -1, 1, None),
    Among("idos", -1, 1, None),
    Among("amos", -1, 1, None),
    Among("áramos", 90, 1, None),
    Among("éramos", 90, 1, None),
    Among("íramos", 90, 1, None),
    Among("ávamos", 90, 1, None),
    Among("íamos", 90, 1, None),
    Among("aríamos", 95, 1, None),
    Among("eríamos", 95, 1, None),
    Among("iríamos", 95, 1, None),
    Among("emos", -1, 1, None),
    Among("aremos", 99, 1, None),
    Among("eremos", 99, 1, None),
    Among("iremos", 99, 1, None),
    Among("ássemos", 99, 1, None),
    Among("êssemos", 99, 1, None),
    Among("íssemos", 99, 1, None),
    Among("imos", -1, 1, None),
    Among("armos", -1, 1, None),
    Among("ermos", -1, 1, None),
    Among("irmos", -1, 1, None),
    Among("ámos", -1, 1, None),
    Among("arás", -1, 1, None),
    Among("erás", -1, 1, None),
    Among("irás", -1, 1, None),
    Among("eu", -1, 1, None),
    Among("iu", -1, 1, None),
    Among("ou", -1, 1, None),
    Among("ará", -1, 1, None),
    Among("erá", -1, 1, None),
    Among("irá", -1, 1, None),
];

static A_7: &'static [Among<Context>; 7] = &[
    Among("a", -1, 1, None),
    Among("i", -1, 1, None),
    Among("o", -1, 1, None),
    Among("os", -1, 1, None),
    Among("á", -1, 1, None),
    Among("í", -1, 1, None),
    Among("ó", -1, 1, None),
];

static A_8: &'static [Among<Context>; 4] = &[
    Among("e", -1, 1, None),
    Among("ç", -1, 2, None),
    Among("é", -1, 1, None),
    Among("ê", -1, 1, None),
];

static G_v: &'static [u8; 20] = &[17, 65, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 19, 12, 2];

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
    };
    let mut among_var;
    let mut i_p2 : i32;
    let mut i_p1 : i32;
    let mut i_pV : i32;
    let v_1 = env.cursor;
    'lab0: loop {
        'replab1: loop{
            let v_2 = env.cursor;
            'lab2: for _ in 0..1 {
                env.bra = env.cursor;
                if (env.cursor + 1 >= env.limit || (env.current.as_bytes()[(env.cursor + 1) as usize] as u8 != 163 as u8 && env.current.as_bytes()[(env.cursor + 1) as usize] as u8 != 181 as u8)) {among_var = 3;}
                else {
                    among_var = env.find_among(A_0, context);
                }
                env.ket = env.cursor;
                match among_var {
                    1 => {
                        env.slice_from("a~");
                    }
                    2 => {
                        env.slice_from("o~");
                    }
                    3 => {
                        if env.cursor >= env.limit {
                            break 'lab2;
                        }
                        env.next_char();
                    }
                    _ => ()
                }
                continue 'replab1;
            }
            env.cursor = v_2;
            break 'replab1;
        }
        break 'lab0;
    }
    env.cursor = v_1;
    'lab3: loop {
        i_pV = env.limit;
        i_p1 = env.limit;
        i_p2 = env.limit;
        let v_3 = env.cursor;
        'lab4: loop {
            'lab5: loop {
                let v_4 = env.cursor;
                'lab6: loop {
                    if !env.in_grouping(G_v, 97, 250) {
                        break 'lab6;
                    }
                    'lab7: loop {
                        let v_5 = env.cursor;
                        'lab8: loop {
                            if !env.out_grouping(G_v, 97, 250) {
                                break 'lab8;
                            }
                            if !env.go_out_grouping(G_v, 97, 250) {
                                break 'lab8;
                            }
                            env.next_char();
                            break 'lab7;
                        }
                        env.cursor = v_5;
                        if !env.in_grouping(G_v, 97, 250) {
                            break 'lab6;
                        }
                        if !env.go_in_grouping(G_v, 97, 250) {
                            break 'lab6;
                        }
                        env.next_char();
                        break 'lab7;
                    }
                    break 'lab5;
                }
                env.cursor = v_4;
                if !env.out_grouping(G_v, 97, 250) {
                    break 'lab4;
                }
                'lab9: loop {
                    let v_6 = env.cursor;
                    'lab10: loop {
                        if !env.out_grouping(G_v, 97, 250) {
                            break 'lab10;
                        }
                        if !env.go_out_grouping(G_v, 97, 250) {
                            break 'lab10;
                        }
                        env.next_char();
                        break 'lab9;
                    }
                    env.cursor = v_6;
                    if !env.in_grouping(G_v, 97, 250) {
                        break 'lab4;
                    }
                    if env.cursor >= env.limit {
                        break 'lab4;
                    }
                    env.next_char();
                    break 'lab9;
                }
                break 'lab5;
            }
            i_pV = env.cursor;
            break 'lab4;
        }
        env.cursor = v_3;
        let v_7 = env.cursor;
        'lab11: loop {
            if !env.go_out_grouping(G_v, 97, 250) {
                break 'lab11;
            }
            env.next_char();
            if !env.go_in_grouping(G_v, 97, 250) {
                break 'lab11;
            }
            env.next_char();
            i_p1 = env.cursor;
            if !env.go_out_grouping(G_v, 97, 250) {
                break 'lab11;
            }
            env.next_char();
            if !env.go_in_grouping(G_v, 97, 250) {
                break 'lab11;
            }
            env.next_char();
            i_p2 = env.cursor;
            break 'lab11;
        }
        env.cursor = v_7;
        break 'lab3;
    }
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_8 = env.limit - env.cursor;
    'lab12: loop {
        'lab13: loop {
            let v_9 = env.limit - env.cursor;
            'lab14: loop {
                let v_10 = env.limit - env.cursor;
                'lab15: loop {
                    let v_11 = env.limit - env.cursor;
                    'lab16: loop {
                        env.ket = env.cursor;
                        if (env.cursor - 2 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((823330 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                            break 'lab16;
                        }

                        among_var = env.find_among_b(A_5, context);
                        if among_var == 0 {
                            break 'lab16;
                        }
                        env.bra = env.cursor;
                        match among_var {
                            1 => {
                                if i_p2 > env.cursor {
                                    break 'lab16;
                                }
                                env.slice_del();
                            }
                            2 => {
                                if i_p2 > env.cursor {
                                    break 'lab16;
                                }
                                env.slice_from("log");
                            }
                            3 => {
                                if i_p2 > env.cursor {
                                    break 'lab16;
                                }
                                env.slice_from("u");
                            }
                            4 => {
                                if i_p2 > env.cursor {
                                    break 'lab16;
                                }
                                env.slice_from("ente");
                            }
                            5 => {
                                if i_p1 > env.cursor {
                                    break 'lab16;
                                }
                                env.slice_del();
                                let v_12 = env.limit - env.cursor;
                                'lab17: loop {
                                    env.ket = env.cursor;
                                    if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((4718616 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                                        env.cursor = env.limit - v_12;
                                        break 'lab17;
                                    }

                                    among_var = env.find_among_b(A_2, context);
                                    if among_var == 0 {
                                        env.cursor = env.limit - v_12;
                                        break 'lab17;
                                    }
                                    env.bra = env.cursor;
                                    if i_p2 > env.cursor {
                                        env.cursor = env.limit - v_12;
                                        break 'lab17;
                                    }
                                    env.slice_del();
                                    match among_var {
                                        1 => {
                                            env.ket = env.cursor;
                                            if !env.eq_s_b(&"at") {
                                                env.cursor = env.limit - v_12;
                                                break 'lab17;
                                            }
                                            env.bra = env.cursor;
                                            if i_p2 > env.cursor {
                                                env.cursor = env.limit - v_12;
                                                break 'lab17;
                                            }
                                            env.slice_del();
                                        }
                                        _ => ()
                                    }
                                    break 'lab17;
                                }
                            }
                            6 => {
                                if i_p2 > env.cursor {
                                    break 'lab16;
                                }
                                env.slice_del();
                                let v_13 = env.limit - env.cursor;
                                'lab18: loop {
                                    env.ket = env.cursor;
                                    if (env.cursor - 3 <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 101 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 108 as u8)) {
                                        env.cursor = env.limit - v_13;
                                        break 'lab18;
                                    }

                                    if env.find_among_b(A_3, context) == 0 {
                                        env.cursor = env.limit - v_13;
                                        break 'lab18;
                                    }
                                    env.bra = env.cursor;
                                    if i_p2 > env.cursor {
                                        env.cursor = env.limit - v_13;
                                        break 'lab18;
                                    }
                                    env.slice_del();
                                    break 'lab18;
                                }
                            }
                            7 => {
                                if i_p2 > env.cursor {
                                    break 'lab16;
                                }
                                env.slice_del();
                                let v_14 = env.limit - env.cursor;
                                'lab19: loop {
                                    env.ket = env.cursor;
                                    if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((4198408 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                                        env.cursor = env.limit - v_14;
                                        break 'lab19;
                                    }

                                    if env.find_among_b(A_4, context) == 0 {
                                        env.cursor = env.limit - v_14;
                                        break 'lab19;
                                    }
                                    env.bra = env.cursor;
                                    if i_p2 > env.cursor {
                                        env.cursor = env.limit - v_14;
                                        break 'lab19;
                                    }
                                    env.slice_del();
                                    break 'lab19;
                                }
                            }
                            8 => {
                                if i_p2 > env.cursor {
                                    break 'lab16;
                                }
                                env.slice_del();
                                let v_15 = env.limit - env.cursor;
                                'lab20: loop {
                                    env.ket = env.cursor;
                                    if !env.eq_s_b(&"at") {
                                        env.cursor = env.limit - v_15;
                                        break 'lab20;
                                    }
                                    env.bra = env.cursor;
                                    if i_p2 > env.cursor {
                                        env.cursor = env.limit - v_15;
                                        break 'lab20;
                                    }
                                    env.slice_del();
                                    break 'lab20;
                                }
                            }
                            9 => {
                                if i_pV > env.cursor {
                                    break 'lab16;
                                }
                                if !env.eq_s_b(&"e") {
                                    break 'lab16;
                                }
                                env.slice_from("ir");
                            }
                            _ => ()
                        }
                        break 'lab15;
                    }
                    env.cursor = env.limit - v_11;
                    if env.cursor < i_pV {
                        break 'lab14;
                    }
                    let v_16 = env.limit_backward;
                    env.limit_backward = i_pV;
                    env.ket = env.cursor;
                    if env.find_among_b(A_6, context) == 0 {
                        env.limit_backward = v_16;
                        break 'lab14;
                    }
                    env.bra = env.cursor;
                    env.slice_del();
                    env.limit_backward = v_16;
                    break 'lab15;
                }
                env.cursor = env.limit - v_10;
                let v_17 = env.limit - env.cursor;
                'lab21: loop {
                    env.ket = env.cursor;
                    if !env.eq_s_b(&"i") {
                        break 'lab21;
                    }
                    env.bra = env.cursor;
                    let v_18 = env.limit - env.cursor;
                    if !env.eq_s_b(&"c") {
                        break 'lab21;
                    }
                    env.cursor = env.limit - v_18;
                    if i_pV > env.cursor {
                        break 'lab21;
                    }
                    env.slice_del();
                    break 'lab21;
                }
                env.cursor = env.limit - v_17;
                break 'lab13;
            }
            env.cursor = env.limit - v_9;
            env.ket = env.cursor;
            if env.find_among_b(A_7, context) == 0 {
                break 'lab12;
            }
            env.bra = env.cursor;
            if i_pV > env.cursor {
                break 'lab12;
            }
            env.slice_del();
            break 'lab13;
        }
        break 'lab12;
    }
    env.cursor = env.limit - v_8;
    let v_19 = env.limit - env.cursor;
    'lab22: loop {
        env.ket = env.cursor;
        among_var = env.find_among_b(A_8, context);
        if among_var == 0 {
            break 'lab22;
        }
        env.bra = env.cursor;
        match among_var {
            1 => {
                if i_pV > env.cursor {
                    break 'lab22;
                }
                env.slice_del();
                env.ket = env.cursor;
                'lab23: loop {
                    let v_20 = env.limit - env.cursor;
                    'lab24: loop {
                        if !env.eq_s_b(&"u") {
                            break 'lab24;
                        }
                        env.bra = env.cursor;
                        let v_21 = env.limit - env.cursor;
                        if !env.eq_s_b(&"g") {
                            break 'lab24;
                        }
                        env.cursor = env.limit - v_21;
                        break 'lab23;
                    }
                    env.cursor = env.limit - v_20;
                    if !env.eq_s_b(&"i") {
                        break 'lab22;
                    }
                    env.bra = env.cursor;
                    let v_22 = env.limit - env.cursor;
                    if !env.eq_s_b(&"c") {
                        break 'lab22;
                    }
                    env.cursor = env.limit - v_22;
                    break 'lab23;
                }
                if i_pV > env.cursor {
                    break 'lab22;
                }
                env.slice_del();
            }
            2 => {
                env.slice_from("c");
            }
            _ => ()
        }
        break 'lab22;
    }
    env.cursor = env.limit - v_19;
    env.cursor = env.limit_backward;
    let v_23 = env.cursor;
    'lab25: loop {
        'replab26: loop{
            let v_24 = env.cursor;
            'lab27: for _ in 0..1 {
                env.bra = env.cursor;
                if (env.cursor + 1 >= env.limit || env.current.as_bytes()[(env.cursor + 1) as usize] as u8 != 126 as u8) {among_var = 3;}
                else {
                    among_var = env.find_among(A_1, context);
                }
                env.ket = env.cursor;
                match among_var {
                    1 => {
                        env.slice_from("ã");
                    }
                    2 => {
                        env.slice_from("õ");
                    }
                    3 => {
                        if env.cursor >= env.limit {
                            break 'lab27;
                        }
                        env.next_char();
                    }
                    _ => ()
                }
                continue 'replab26;
            }
            env.cursor = v_24;
            break 'replab26;
        }
        break 'lab25;
    }
    env.cursor = v_23;
    return true
}
