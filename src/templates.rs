use crate::files;
use anyhow::{Result, bail};
use std::{fs, io::Write, path::Path};
use zip::{ZipWriter, write::SimpleFileOptions};
const REL: &str = "http://schemas.openxmlformats.org/package/2006/relationships";
const OFFICE: &str = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
pub fn formats() -> serde_json::Value {
    serde_json::json!([
    {"id":"txt","name":"纯文本","ext":"txt","color":"gray"},
    {"id":"md","name":"Markdown","ext":"md","color":"blue"},
    {"id":"docx","name":"Word 文档","ext":"docx","color":"blue"},
    {"id":"xlsx","name":"Excel 表格","ext":"xlsx","color":"green"},
    {"id":"pptx","name":"PowerPoint","ext":"pptx","color":"orange"},
    {"id":"rtf","name":"富文本","ext":"rtf","color":"purple"},
    {"id":"xml","name":"XML","ext":"xml","color":"orange"},
    {"id":"json","name":"JSON","ext":"json","color":"green"},
    {"id":"html","name":"HTML","ext":"html","color":"orange"},
    {"id":"rs","name":"Rust 源文件","ext":"rs","color":"orange"},
    {"id":"py","name":"Python","ext":"py","color":"blue"},
    {"id":"sh","name":"Shell 脚本","ext":"sh","color":"gray"},
    {"id":"svg","name":"SVG 矢量图","ext":"svg","color":"purple"},
    {"id":"psd","name":"Photoshop","ext":"psd","color":"blue"},
    {"id":"ai","name":"Illustrator (EPS)","ext":"ai","color":"orange"}
    ])
}
pub fn create(p: &Path, format: &str) -> Result<()> {
    match format {
"docx"|"xlsx"|"pptx"=>office(p,format),
"psd"=>{let mut b=vec![];b.extend_from_slice(b"8BPS\x00\x01\x00\x00\x00\x00\x00\x00\x00\x03");b.extend_from_slice(&1u32.to_be_bytes());b.extend_from_slice(&1u32.to_be_bytes());b.extend_from_slice(&[0,8,0,3]);b.extend_from_slice(&[0;12]);b.extend_from_slice(&[0,0,255,255,255]);files::write_new(p,&b)},
"ai"=>files::write_new(p,b"%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 512 512\n%%Creator: RightClick\n%%EndComments\nshowpage\n%%EOF\n"),
other=>{let content=match other{"txt"|"md"|"rs"|"py"=>"","rtf"=>"{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 \\par}","xml"=>"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root/>\n","json"=>"{}\n","html"=>"<!doctype html>\n<html lang=\"zh-CN\"><meta charset=\"utf-8\"><title>新页面</title><body></body></html>\n","svg"=>"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"512\" height=\"512\"></svg>\n","sh"=>"#!/bin/sh\n","custom"=>"",_=>bail!("此格式请先导入一个模板文件")};files::write_new(p,content.as_bytes())}}
}
fn office(p: &Path, format: &str) -> Result<()> {
    let f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(p)?;
    let mut z = ZipWriter::new(f);
    let mut add = |path: &str, text: String| -> Result<()> {
        z.start_file(
            path,
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated),
        )?;
        z.write_all(text.as_bytes())?;
        Ok(())
    };
    let (main, mime) = match format {
        "docx" => ("word/document.xml", "wordprocessingml.document.main+xml"),
        "xlsx" => ("xl/workbook.xml", "spreadsheetml.sheet.main+xml"),
        _ => (
            "ppt/presentation.xml",
            "presentationml.presentation.main+xml",
        ),
    };
    let extra = match format {
        "xlsx" => {
            "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        _ => "",
    };
    add(
        "[Content_Types].xml",
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/{main}\" ContentType=\"application/vnd.openxmlformats-officedocument.{mime}\"/>{extra}</Types>"
        ),
    )?;
    add(
        "_rels/.rels",
        format!(
            "<Relationships xmlns=\"{REL}\"><Relationship Id=\"rId1\" Type=\"{OFFICE}/officeDocument\" Target=\"{main}\"/></Relationships>"
        ),
    )?;
    match format{"docx"=>add(main,"<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p/><w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/></w:sectPr></w:body></w:document>".into())?,
"xlsx"=>{add(main,format!("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"{OFFICE}\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"))?;add("xl/_rels/workbook.xml.rels",format!("<Relationships xmlns=\"{REL}\"><Relationship Id=\"rId1\" Type=\"{OFFICE}/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>"))?;add("xl/worksheets/sheet1.xml","<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData/></worksheet>".into())?},
_=>add(main,"<p:presentation xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>".into())?};
    z.finish()?;
    Ok(())
}
