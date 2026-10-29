/**
 * @name Extracted Findle declarations
 * @description Lists files with extracted Swift declarations, not merely archived source files.
 * @kind table
 * @id findle/extracted-source-files
 */
import swift

from Decl declaration
select declaration.getFile().getRelativePath() as path
