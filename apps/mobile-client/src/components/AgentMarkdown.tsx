import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import styles from './AgentMarkdown.module.css';

export default function AgentMarkdown({ text }: { text: string }) {
  return <div className={styles.content}>
    <Markdown remarkPlugins={[remarkGfm]} skipHtml components={{
      a: ({ children, href }) => <a href={href} target="_blank" rel="noreferrer">{children}</a>,
      img: ({ alt, src }) => <a href={src} target="_blank" rel="noreferrer">{alt || 'Open image'}</a>,
      table: ({ children }) => <div className={styles.tableWrap}><table>{children}</table></div>,
    }}>{text}</Markdown>
  </div>;
}
