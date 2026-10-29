//! olife-gateway (`sockets_auth`): the production gateway of Olife (OLIFE_ARCHITECTURE §1, §5).
//! The reference behaviour is tools/olife/gateway_dev.py; codecs are generated from tools/olife/protocol/*.yaml.
pub mod admin;
pub mod auth;
pub mod bans;
pub mod config;
pub mod gateway;
pub mod log;
pub mod packs;
pub mod proto;
pub mod ticket;
pub mod util;
